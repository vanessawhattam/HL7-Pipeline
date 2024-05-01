library(tidyverse)
library(mosaic)
library(janitor)
library(Metrics)
library(tis)
library(Rnssp)
library(TTR)
library(zoo)
library(forecast)
library(DBI)
library(odbc)


# Read in the datasets ---------------------------------------------------------

# Connect to the SQL Server database using the ODBC DSN
con <- dbConnect(odbc::odbc(), 
                 dsn = "SQL_Server_Connection")

# Option 2: Switch Database using SQL commands
dbExecute(con, "USE ELRDQMS")


combined_df <- dbGetQuery(con, "Select *
                 FROM source_data")

facilities_hco <- read_csv("//state.mt.ads/HHS/Shared/PHSD/DIV-SHARE/OESS/Surveillance and Informatics Section/Special Projects/ELR_data_quality_monitoring/elr-data-monitoring-system/facility_list.csv")

#  ------------------------------------------------------------------------------

d1 <- combined_df %>%
  mutate(date = str_sub(MSH_1_6, 1, 8),
         date = as.Date.character(date, tryFormats = c("%Y%m%d")),
         countervar = 1) %>%
  separate_wider_delim(MSH_1_3, delim = "^", names = c("facility_name", "CLIA", "identifier"), too_few = "align_start") %>%
  inner_join(facilities_hco, by = c("CLIA", "facility_name")) %>%
  distinct() %>%
  group_by(clean_facility_name, date) %>%
  summarise(count = sum(countervar)) %>%
  ungroup() %>%
  filter(!is.na(clean_facility_name))

# Define the date range
date_range <- seq(as.Date("2022-10-01"), Sys.Date(), by = "day")

# Create a data frame with all combinations of MSH-1.3 values and dates
all_combinations <- crossing(clean_facility_name = unique(d1$clean_facility_name), date = date_range)

# Left join with your summarized dataset
d1 <- all_combinations %>%
  left_join(d1, by = c("clean_facility_name", "date")) %>%
  mutate(count = coalesce(count, 0))  # Replace NAs with 0 for count

# Clean the environment
rm(all_combinations)

# EWMA -------------------------------------------------------------------------

# Define the confidence level (e.g., 95%)
confidence_level <- 0.95

# Critical value for the confidence level
z <- qnorm((1 + confidence_level) / 2)

# Function to calculate prediction intervals based on the standard deviation
calculate_prediction_intervals <- function(predicted_value, standard_deviation) {
  lower_bound <- predicted_value - z * standard_deviation
  upper_bound <- predicted_value + z * standard_deviation
  return(c(lower_bound, upper_bound))
}

facilities <- unique(d1$clean_facility_name)

ewma_df <- tibble()


for (x in facilities) {
  df <- d1 %>%
    filter(clean_facility_name == x) 
  
  ewma_volume <- zoo(df$count)
  
  ewma_volume <- EMA(ewma_volume)
  
  df <- df %>%
    mutate(date = as.Date(date),
           ewma_pred = round(ewma_volume, digits = 3), 
           difference = round(count - ewma_pred, digits = 3),
           percent_difference = round(((count - ewma_pred)/ewma_pred)*100, digits = 3),
           standard_deviation = round(sd(difference, na.rm = TRUE), digits = 3), # Calculate standard deviation, excluding NA values
           lower_bound = round(ewma_pred - z * standard_deviation, digits = 3),
           upper_bound = round(ewma_pred + z * standard_deviation, digits = 3),
           alert = case_when(count > upper_bound ~ 2,
                             count == 0 ~ 1,
                             .default = 0))
  
  ewma_df <- ewma_df %>%
    rbind(df)
}

# Make sure we only include messages that had a facility name
ewma_df <- ewma_df %>%
  filter(!is.na(clean_facility_name))

# Write to CSV because SQL database isn't up yet
write_csv(ewma_df, "//state.mt.ads/HHS/Shared/PHSD/DIV-SHARE/OESS/Surveillance and Informatics Section/Special Projects/ELR_data_quality_monitoring/elr-data-monitoring-system/ewma_df.csv", na = "")


# ewma_df <- ewma_df %>%
#   filter(!is.na(facility_name))
# 
# mae <- mean(abs(ewma_df$difference), na.rm = T)
# 
# # Calculate MSE
# mse <- mean(ewma_df$difference^2, na.rm = T)
# 
# # Calculate RMSE
# rmse <- sqrt(mse)
# 
# # Print the results
# cat("MAE:", mae, "\n",
#     "MSE:", mse, "\n",
#     "RMSE:", rmse)
# 
# 
# # Prepare for visualizing the data
# ewma_eval <- ewma_df %>%
#   select(date, count, ewma_pred, clean_facility_name) %>%
#   pivot_longer(cols = c(count, ewma_pred), names_to = "method", values_to = "value") %>%
#   #mutate(month_year = paste0(month, "-", year)) %>%
#   filter(!is.na(value))  %>%
#   filter(str_starts(clean_facility_name, "Benefis Hospital")) %>%
#   arrange(date)
# 
# 
# ggplot(ewma_eval, aes(x = date, y = value, group = method)) +
#   geom_line(aes(color = method)) +
#   ylab("Count of ELRs") + 
#   theme_minimal() + 
#   scale_color_manual(values = c("cyan", "hotpink"), 
#                      labels = c("ELR Count", "EWMA Prediction"))



# Data element validation -------------------------------------------------------
data_elements <- combined_df %>%
  mutate(date = as.POSIXlt(str_sub(msh_1_6, 1, 14), 
                           format = "%Y%m%d%H%M%S"),
         date = as.Date(date),
         test_date = as.POSIXlt(str_sub(obx_1_14, 1, 14),
                                format = "%Y%m%d%H%M%S"),
         test_date = as.Date(test_date),
         countervar = 1,
         msg_lag_hours = as.numeric(difftime(date, 
                                             test_date,
                                             units = "hours")),
         msg_lag_hours = case_when(is.na(msg_lag_hours) ~ 0,
                                   .default = as.numeric(msg_lag_hours))) %>%
  separate_wider_delim(msh_1_3, 
                       delim = "^", 
                       names = c("facility_name", 
                                 "CLIA", 
                                 "identifier"), too_few = "align_start") %>%
  left_join(facilities_hco, by = c("facility_name" = "facility_name", "CLIA" = "CLIA")) %>%
  group_by(clean_facility_name,
           date) %>%
  summarise('Msg ID' = (sum(is.na(msh_1_9)) / n())*100,
            Ethnicity = (sum(is.na(pid_1_22)) / n())*100,
            Race = (sum(is.na(pid_1_10)) / n())*100,
            'Patient Name' = (sum(is.na(pid_1_5)) / n())*100,
            DOB = (sum(is.na(pid_1_7)) / n())*100,
            Sex = (sum(is.na(pid_1_8)) / n())*100,
            Address = (sum(is.na(pid_1_11)) / n())*100,
            Phone = (sum(is.na(pid_1_13)) / n())*100,
            # MRN = (sum(is.na(pid_1_18)) / n())*100,
            'Patient Class' = (sum(is.na(pv1_1_2)) / n())*100,
            'Patient Location' = (sum(is.na(pv1_1_3)) / n())*100,
            # 'Chief Complaint' = (sum(is.na(nte_1_3)) / n())*100,
            'ORC Accession ID' = (sum(is.na(orc_1_3)) / n())*100,
            'OBR Accession ID' = (sum(is.na(obr_1_3)) / n())*100,
            'Message Lag (Hours)' = mean(msg_lag_hours)
  ) %>%
  pivot_longer('Msg ID':'OBR Accession ID', 
               names_to = "segment", 
               values_to = "percent_blank") %>%
  ungroup() %>%
  mutate(blank_alert = case_when(percent_blank >= .2 ~ "alert", 
                                 .default = "expected"))  



write_csv(data_elements, "//state.mt.ads/HHS/Shared/PHSD/DIV-SHARE/OESS/Surveillance and Informatics Section/Special Projects/ELR_data_quality_monitoring/elr-data-monitoring-system/data_elements.csv")
















# These models are retired -----------------------------------------------------


# ARIMA Model ------------------------------------------------------------------
library(Rnssp)

myProfile <- readRDS("~/myProfile.rds")

benefis_url <- "https://essence.syndromicsurveillance.org/nssp_essence/api/tableBuilder/csv?datasource=va_er&startDate=7Nov2023&medicalGroupingSystem=essencesyndromes&userId=5885&endDate=5Feb2024&percentParam=noPercent&erFacility=16616&aqtTarget=TableBuilder&geographySystem=region&detector=probrepswitch&timeResolution=daily&rowFields=timeResolution&columnField=cDeath"

benefis_ed <- get_essence_data(benefis_url, start_date = "2022-10-01", end_date = "2024-02-22", profile = myProfile) %>%
  clean_names()

ed_visits <- benefis_ed %>%
  mutate(visit_count = no+yes) %>%
  rename(date = time_resolution) %>%
  select(-c(no, yes))

weather_data <- read_rds("//state.mt.ads/HHS/Shared/PHSD/DIV-SHARE/OESS/Surveillance and Informatics Section/Syndromic Surveillance/projects/health-and-air-dashboard/aqi_data.RDS")

aqi <- weather_data %>%
  filter(sitename == "Great Falls") %>%
  group_by(date) %>%
  summarise(mean_aqi = mean(aqi_value_1))

train <- d1 %>%
  filter(str_starts(clean_facility_name, "Benefis Hospital")) %>%
  left_join(ed_visits, by = "date") %>%
  left_join(aqi, by = "date") %>%
  select(-c(clean_facility_name, date))

benefis_date <- d1 %>%
  filter(str_starts(clean_facility_name, "Benefis Hospital"))


arimax_model <- auto.arima(train$count, xreg = cbind(train$visit_count, train$mean_aqi))
summary(arimax_model)

# Forecast using the ARIMAX model
forecast_values <- forecast(arimax_model, xreg = cbind(train$visit_count, train$mean_aqi))


# Adding the forecasted values to the original dataframe
arimax_eval <- train %>%
  mutate(arimax_forecast = forecast_values$mean,
         date = benefis_date$date) %>%
  relocate(arimax_forecast, .after = count) %>%
  select(-c(mean_aqi, visit_count)) %>%
  pivot_longer(cols = c(count, arimax_forecast), names_to = "method", values_to = "value")


ggplot(arimax_eval, aes(x = count, y = arimax_forecast)) +
  geom_point() + 
  geom_abline(slope = 1) +
  theme_minimal() 



ggplot(arimax_eval, aes(x = date, y = value, group = method)) +
  geom_line(aes(color = method)) +
  ylab("Count of ELRs") +
  theme_minimal() +
  scale_color_manual(values = c("hotpink", "cyan"),
                     labels = c("ELR Count", "ARIMAX Prediction"))



# Linear Regression Model ------------------------------------------------------
searches <- read.csv("multiTimeline (1).csv") %>%
  clean_names()

train <- d1 %>%
  filter(date < Sys.Date() - 21) %>%
  mutate(day_of_year= day(date),
         week_of_year = week(date),
         resp_season = case_when(!between(week_of_year, 21, 40) ~ "yes", 
                                 .default = "no"),
         day_of_week = wday(date),
         school_year = case_when(between(week_of_year, 24, 36) ~ "no",
                                 .default = "yes"),
         holiday = case_when(isHoliday(date) == T ~ "yes",
                             .default = "no")) %>%
  left_join(ed_visits, by = "date") %>%
  left_join(searches, by = c("week_of_year" = "week_num"))

test <- d1 %>%
  filter(date >= Sys.Date() - 21) %>%
  mutate(day_of_year= day(date),
         week_of_year = week(date),
         resp_season = case_when(!between(week_of_year, 21, 40) ~ "yes", 
                                 .default = "no"),
         day_of_week = wday(date),
         school_year = case_when(between(week_of_year, 24, 36) ~ "no",
                                 .default = "yes"),
         holiday = case_when(isHoliday(date) == T ~ "yes",
                             .default = "no")) %>%
  left_join(ed_visits, by = "date") %>%
  left_join(searches, by = c("week_of_year" = "week_num"))

volume_lm <- lm(log(count) ~ week_of_year + resp_season + visit_count +  covid + flu, train)

summary(volume_lm)

test_with_preds <- test %>%
  bind_cols(exp(predict(volume_lm, test))) %>% 
  rename(predicted_count = ...18) %>%
  mutate(predicted_count = round(predicted_count, digits = 2),
         difference = count - predicted_count,
         percent_difference = ((predicted_count - count)/count)*100) %>%
  relocate(predicted_count, .after = count)

















