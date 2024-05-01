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

# Option 2: Switch Database using SQL commands
dbExecute(con, "USE ELRDQMS")

# Add the source data as an object in R
combined_df <- dbGetQuery(con, "Select *
                 FROM source_data")


# Okay so I've identified my paired columns
# Now, I need to figure out how to apply it to my data table
# I need to apply the case_when to when the _3 column is covid and the _5 is detected

obx_test_name_cols <- tibble(test_colname = grep("OBX_\\d{1,2}_3", colnames(combined_df), value = TRUE),
                             obx_num = str_sub(test_colname, 5,-3))
obx_test_result_cols <- tibble(result_colname = grep("OBX_\\d{1,2}_5", colnames(combined_df), value = TRUE),
                               obx_num = str_sub(result_colname, 5,-3))

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

# col_pairs has the pairs of all of my columns
# so I need something like "if col in test_col matches covid test pattern AND col in result_col matches covid result pattern (this needs to be row-wise), then value in condition column should be "COVID positive" else "other" 

# Assuming condition_test is your dataframe and col_pairs is your col_pairs dataframe

# Vectorized function to check if both test and result columns match patterns
check_covid <- function(test_col, result_col) {
  test_matches <- grepl(covid_test_pattern, test_col, ignore.case = TRUE)
  result_matches <- grepl(covid_result_pattern, result_col, ignore.case = TRUE)
  if (any(test_matches) && any(result_matches)) {
    return("COVID positive")
  } else {
    return("other")
  }
}

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

# Define the date range
date_range <- seq(as.Date("2022-10-01"), Sys.Date(), by = "day")

# Create a covid dataframe
covid_test <- condition_test %>%
  complete(date = date_range) %>%
  filter(date %in% c(date_range),
         condition %in% c(NA, "COVID positive")) %>%
  mutate(condition = case_when(is.na(condition) ~ "COVID positive",
                                .default = as.character(condition)),
         date = as.Date(date),
         week = week(date),
         year = year(date),
         count = if_else(is.na(count), 0, count)) %>%
  group_by(condition, date, week, year) %>%
  summarise(count = sum(count)) %>%
  ungroup()



covid_ewma_volume <- zoo(covid_test$count)

covid_ewma_volume <- EMA(covid_ewma_volume)

covid_test <- covid_test %>%
  mutate(date = as.Date(date),
         covid_ewma_pred = covid_ewma_volume,
         difference = count - covid_ewma_pred,
         standard_deviation = sd(difference, na.rm = TRUE), # Calculate standard deviation, excluding NA values
         lower_bound = covid_ewma_pred - z * standard_deviation,
         upper_bound = covid_ewma_pred + z * standard_deviation,
         alert = case_when(count > upper_bound ~ 2,
                           count == 0 ~ 1,
                           .default = 0),
         percent_difference = ((count - lag(count))/lag(count))*100
         )


write_csv(covid_test, "//state.mt.ads/HHS/Shared/PHSD/DIV-SHARE/OESS/Surveillance and Informatics Section/Special Projects/ELR_data_quality_monitoring/elr-data-monitoring-system/covid_data.csv")
  

