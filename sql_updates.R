library(DBI)
library(odbc)

# Connect to the SQL Server database using the ODBC DSN
con <- dbConnect(odbc::odbc(), 
                 dsn = "SQL_Server_Connection")

# Switch Database using SQL commands
dbExecute(con, "USE ELRDQMS")


# Check how many rows the source data table has
dbGetQuery(con, "Select Count (*)
                 FROM source_data")

# Write to EWMA table ----------------------------------------------------------

table_schema <- "CREATE TABLE ewma_data (
                  clean_facility_name TEXT,
                  date DATE,
                  count INT,
                  ewma_pred DECIMAL (38, 4),
                  difference DECIMAL (38, 4),
                  percent_difference DECIMAL (38, 4),
                  standard_deviation DECIMAL (38, 4),
                  lower_bound DECIMAL (38, 4),
                  upper_bound DECIMAL (38, 4),
                  alert INT
                )"

create_ewma_df <- paste0("IF NOT EXISTS (SELECT * FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'ewma_data')
                          BEGIN ", table_schema, " END")



# Execute the SQL query to create the table
dbExecute(con, create_ewma_df)

# Write the ewma_df table to SQL 
dbWriteTable(con, "ewma_data", ewma_df, append = TRUE)


query <- "SELECT * FROM ewma_data"
query_result <- dbGetQuery(con, query)


# Close the database connection when finished
dbDisconnect(con)







