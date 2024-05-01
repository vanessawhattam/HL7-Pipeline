# Get the libraries we need
library(tidyverse)
library(mosaic)
library(janitor)
library(Metrics)
library(tis)
library(TTR)
library(zoo)
library(forecast)
library(DBI)
library(odbc)

# Read in the dataset ---------------------------------------------------------

# Connect to the SQL Server database using the ODBC DSN
con <- dbConnect(odbc::odbc(), 
                 dsn = "SQL_Server_Connection")

# Make sure we're using the correct database in our SQL Server environment
dbExecute(con, "USE ELRDQMS")

# Add the source data as an object in R
combined_df <- dbGetQuery(con, "Select *
                 FROM source_data")


# Create column pairs for the test name column and result column --------------------
# OBX_D_3 is the test and OBX_D_5 is the result where D is a digit

# Create a table of all of the test name columns
obx_test_name_cols <- tibble(test_colname = grep("OBX_\\d{1,2}_3", 
                                                 colnames(combined_df), 
                                                 value = TRUE),
                             obx_num = str_sub(test_colname, 5,-3))

# And then create a table of all the test result columns
obx_test_result_cols <- tibble(result_colname = grep("OBX_\\d{1,2}_5", 
                                                     colnames(combined_df), 
                                                     value = TRUE),
                               obx_num = str_sub(result_colname, 5,-3))

# Then join those two tables together so our tests and results are paired
col_pairs <- obx_test_name_cols %>%
  left_join(obx_test_result_cols) %>% 
  relocate(obx_num, .after = result_colname)

# Create a dataframe grouped by condition 
condition_test <- combined_df %>%
  mutate(countervar = 1,
         date = as.Date(str_sub(MSH_1_6, 1, 8), format = "%Y%m%d")) %>%
  group_by(across(starts_with("OBX")), date) %>%
  summarise(count = sum(countervar)) %>%
  ungroup() 


# Let's see if we can get these cols to match ----------------------------------
covid_test_pattern <- "COVID-19|CoV|SARS coronavirus|Covid-19 PCR|COVID|SARS CORONAVIRUS 2|SARS coronavirus 2|SARS-COV-2|SARS-CoV-2|SARS-related coronavirus|COVPCR|COV2|COVIDBC"
covid_result_pattern <- "^Detected|^detected|^SARS-CoV-2|^COVID 19 Detected|^Identified|^SARS-CoV-2 DETECTED|^DETECTED|^SARS-CoV-2 RNA DETECTED|Positive|POSITIVE"

# Create an empty condition column in condition_test dataframe
condition_test$condition <- NA

# Loop through each row of col_pairs
for (i in 1:nrow(col_pairs)) {
  test_col <- col_pairs$test_colname[i]
  result_col <- col_pairs$result_colname[i]
  
  # Check if the columns exist in condition_test
  if (test_col %in% names(condition_test) && result_col %in% names(condition_test)) {
    # Check if both test and result columns match patterns
    test_matches <- grepl(covid_test_pattern, condition_test[[test_col]], ignore.case = TRUE)
    result_matches <- grepl(covid_result_pattern, condition_test[[result_col]], ignore.case = TRUE)
    
    # Update condition column based on the matches
    condition_test$condition[test_matches & result_matches] <- "COVID positive"
  }
}

# Fill remaining NA values with "other"
condition_test$condition[is.na(condition_test$condition)] <- "other"



#--------------------------------------------------------------------------------

# Define the date range. Start on 2022-10-01 because that's the earliest data
date_range <- seq(as.Date("2022-10-01"), Sys.Date(), by = "day")

# Create a covid dataframe
covid_test <- condition_test %>%
  # Fill in any days that are missing from the date range
  complete(date = date_range) %>%
  # Make sure we don't have any erroneous future dates in the dataframe
  filter(date %in% c(date_range),
          # We keep the NA condition values b/c those are the rows we created
          # for the missing dates - their counts will be 0, but we still need them
         condition %in% c(NA, "COVID positive")) %>%
  # Change the NA values to COVID positive 
  mutate(condition = case_when(is.na(condition) ~ "COVID positive",
                                .default = as.character(condition)),
         # Create date, week, and year columns
         date = as.Date(date),
         week = week(date),
         year = year(date),
         # Modify the count column so that NAs are changed to 0
         count = if_else(is.na(count), 0, count)) %>%
  # Group by date
  group_by(condition, date, week, year) %>%
  # Get the total number of COVID positives for each day
  summarise(count = sum(count)) %>%
  ungroup()

# Run EWMA on COVID data ----------------------------------------------------------

# Create time series data out of the COVID counts
covid_ewma_volume <- zoo(covid_test$count)

# Run the EWMA on the newly created COVID time series data
covid_ewma_volume <- EMA(covid_ewma_volume)

# Add the results of the EWMA back to the dataframe
covid_test <- covid_test %>%
  # Make sure date column is formatted correctly
  mutate(date = as.Date(date),
         # Add a column for the predictions generated by EWMA
         covid_ewma_pred = covid_ewma_volume,
         # Find the difference between the predicted and actual values
         difference = count - covid_ewma_pred,
         # Calculate the standard deviation 
         standard_deviation = sd(difference, na.rm = TRUE), 
         # Calculate the upper confidence interval - 97.5% confidence
         upper_bound = covid_ewma_pred + (z * standard_deviation),
         # Add alerts column for when actual values are above CI or count is 0
         alert = case_when(count > upper_bound ~ 2,
                           count == 0 ~ 1,
                           .default = 0),
         # Calculate the difference in count from the previous day
         # This helps us know day to day how different the positive test counts are
         percent_difference = ((count - lag(count))/lag(count))*100
         )

# Write to CSV because that's what Tableau storyboard uses 
write_csv(covid_test, "covid_data.csv")
  

