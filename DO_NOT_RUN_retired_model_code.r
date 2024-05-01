# Retired models
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


