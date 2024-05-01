# Read in packages
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

# Read in the datasets ---------------------------------------------------------

# Connect to the SQL Server database using the ODBC DSN
con <- dbConnect(odbc::odbc(), 
                 dsn = "SQL_Server_Connection")

# Make sure we're using the correct database in our SQL Server environment
dbExecute(con, "USE ELRDQMS")

# Add the source data as an object in R
combined_df <- dbGetQuery(con, "Select *
                 FROM source_data")

# Read in the facility list with clean facility names
facilities_hco <- read_csv("facility_list.csv")

# Transform the data -------------------------------------------------------------

# Create a new dataset that will be the basis for the EWMA model
d1 <- combined_df %>%
  # Create a date column from the MSH-1.6 segment
  mutate(date = str_sub(MSH_1_6, 1, 8),
         date = as.Date.character(date, 
                                  tryFormats = c("%Y%m%d")),
         countervar = 1) %>%
  # Separate out the facility name from the CLIA and ID Type in the MSH-1.3 segment
  separate_wider_delim(MSH_1_3, 
                       delim = "^", 
                       names = c("facility_name", 
                                 "CLIA", 
                                 "identifier"), 
                       too_few = "align_start") %>%
  # Join the clean facility names 
  inner_join(facilities_hco, 
             by = c("CLIA",  
                    "facility_name")) %>%
  distinct() %>%
  # Group by facility and date
  group_by(clean_facility_name, date) %>%
  # Obtain the count of ELRs for the facility and date
  summarise(count = sum(countervar)) %>%
  ungroup() %>%
  # Get rid of any rows where there is no facility name
  filter(!is.na(clean_facility_name))

# Add rows for facility/date combos that don't have any ELRs -------------------

# Define the date range. Start on 2022-10-01 because that's the earliest data day
date_range <- seq(as.Date("2022-10-01"), Sys.Date(), by = "day")

# Create a data frame with all combinations of facility names and dates
all_combinations <- crossing(clean_facility_name = unique(d1$clean_facility_name), 
                             date = date_range)

# Left join with the d1 dataset
d1 <- all_combinations %>%
  left_join(d1, by = c("clean_facility_name", "date")) %>%
  mutate(count = coalesce(count, 0))  # Replace NAs with 0 for count

# Clean the environment
rm(all_combinations)

# EWMA -------------------------------------------------------------------------

# Define the confidence level 
confidence_level <- 0.95

# Critical value for the confidence level
z <- qnorm((1 + confidence_level) / 2)

# Function to calculate prediction intervals based on the standard deviation
calculate_prediction_intervals <- function(predicted_value, standard_deviation) {
  lower_bound <- predicted_value - z * standard_deviation
  upper_bound <- predicted_value + z * standard_deviation
  return(c(lower_bound, upper_bound))
}

# Get a list of the unique facility names 
# Use this to run EWMA model for each individual facility
facilities <- unique(d1$clean_facility_name)

# Create a dataframe to hold all of the EWMA model results
ewma_df <- tibble()

# Iterate through our list of facilities and run EWMA
for (x in facilities) {
  # Filter to only include facility of interest
  df <- d1 %>%
    filter(clean_facility_name == x) 
  
  # Turn the `count` column into time series data
  ewma_volume <- zoo(df$count)
  
  # Run EWMA on the new time series data
  ewma_volume <- EMA(ewma_volume)
  
  # Add in conf intervals, alerts, etc
  df <- df %>%
    # Ensure the date column is formatted as date
    mutate(date = as.Date(date),
           # Add the EWMA prediction to the dataframe
           ewma_pred = round(ewma_volume, digits = 3), 
           # Calculate the difference between the actual and predicted values
           difference = round(count - ewma_pred, digits = 3),
           # And the percent difference between the actual and predicted values
           percent_difference = round(((count - ewma_pred)/ewma_pred)*100, 
                                      digits = 3),
            # Calculate standard deviation, excluding NA values
           standard_deviation = round(sd(difference, na.rm = TRUE), digits = 3),
           # Calculate the upper 97.5% confidence intervals
           upper_bound = round(ewma_pred + z * standard_deviation, digits = 3),
           # Add an alert column 
           alert = case_when(count > upper_bound ~ 2,
                             count == 0 ~ 1,
                             .default = 0))
  
  # Add the dataframe to the overall EWMA dataframe
  ewma_df <- ewma_df %>%
    rbind(df)
}

# Make sure we only include messages that had a facility name
ewma_df <- ewma_df %>%
  filter(!is.na(clean_facility_name))

# Write to CSV because that's how Tableau reads it currently
write_csv(ewma_df, "ewma_df.csv", na = "")

# Calculate the metrics on the EWMA predictions
# Calculate MAE first
mae <- mean(abs(ewma_df$difference), na.rm = T)

# Calculate MSE
mse <- mean(ewma_df$difference^2, na.rm = T)
 
# Calculate RMSE
rmse <- sqrt(mse)

# Print the results
# Check to make sure the metrics aren't outrageous
cat("MAE:", mae, "\n",
    "MSE:", mse, "\n",
    "RMSE:", rmse)




# Data element validation -------------------------------------------------------

# Check for blanks
data_elements <- combined_df %>%
  # Format the date column as a date
  mutate(date = as.POSIXlt(str_sub(MSH_1_6, 1, 14), 
                           format = "%Y%m%d%H%M%S"),
         date = as.Date(date),
         # Format the OBX date as a date
         test_date = as.POSIXlt(str_sub(OBX_1_14, 1, 14),
                                format = "%Y%m%d%H%M%S"),
         test_date = as.Date(test_date),
         countervar = 1,
         # Calculate the lag between when message was sent and when lab was performed
         msg_lag_hours = as.numeric(difftime(date, 
                                             test_date,
                                             units = "hours")),
         # Change to 0 instead of NA so we can calculate mean later
         msg_lag_hours = case_when(is.na(msg_lag_hours) ~ 0,
                                   .default = as.numeric(msg_lag_hours))) %>%
  # Separate the facility info into name, CLIA, and ID type
  separate_wider_delim(MSH_1_3, 
                       delim = "^", 
                       names = c("facility_name", 
                                 "CLIA", 
                                 "identifier"), too_few = "align_start") %>%
  # Join the clean facility name table
  left_join(facilities_hco, by = c("facility_name" = "facility_name", "CLIA" = "CLIA")) %>%
  # Group by facility and date
  group_by(clean_facility_name,
           date) %>%
  # Check for blank percentage in the data elements of interest
  summarise('Msg ID' = (sum(is.na(MSH_1_9)) / n())*100,
            Ethnicity = (sum(is.na(MSH_1_22)) / n())*100,
            Race = (sum(is.na(PID_1_10)) / n())*100,
            'Patient Name' = (sum(is.na(PID_1_5)) / n())*100,
            DOB = (sum(is.na(PID_1_7)) / n())*100,
            Sex = (sum(is.na(PID_1_8)) / n())*100,
            Address = (sum(is.na(PID_1_11)) / n())*100,
            Phone = (sum(is.na(PID_1_13)) / n())*100,
            # MRN = (sum(is.na(PID_1_18)) / n())*100,
            'Patient Class' = (sum(is.na(PV1_1_2)) / n())*100,
            'Patient Location' = (sum(is.na(PV1_1_3)) / n())*100,
            # 'Chief Complaint' = (sum(is.na(NTE_1_3)) / n())*100,
            'ORC Accession ID' = (sum(is.na(ORC_1_3)) / n())*100,
            'OBR Accession ID' = (sum(is.na(OBR_1_3)) / n())*100,
            'Message Lag (Hours)' = mean(msg_lag_hours)
  ) %>%
  # Pivot longer so we can use it in Tableau
  pivot_longer('Msg ID':'OBR Accession ID', 
               names_to = "segment", 
               values_to = "percent_blank") %>%
  ungroup() %>%
  # Add an alert for when the blank percentage is >20% 
  mutate(blank_alert = case_when(percent_blank >= .2 ~ "alert", 
                                 .default = "expected"))  


# Write to a csv so we can use it Tableau
write_csv(data_elements, "data_elements.csv")















