import os
import re
import shutil
import pyodbc
import tempfile

import numpy as np
import pandas as pd

from sqlalchemy import create_engine
from datetime import datetime, timedelta


# Function to clean the column names
def sanitize_column_name(name):
    return re.sub(r'[^a-zA-Z0-9_]', '_', name)


# Function to process HL7 message correctly
def process_hl7_messages(hl7_messages):
    # Separate the segment header and field value 
    data = {'segment': [], 
            'field_value': []
            }
    # Count the field number of the segment 
    segment_counter = {}

    # From the list of hl7 messages
    for message in hl7_messages:
        # Split into segments by newlines '\n'
        segments = message.strip().split('\n')  
        for segment in segments:
            if segment:
                # Split our segment by the delimiter "|"
                parts = segment.split('|')
                if len(parts) > 1:  # Ensure the segment has values
                    # Get the name of the segment
                    segment_label, *segment_values = parts
                    # Make the suffix the segment number
                    suffix = segment_counter.get(segment_label, 0) + 1
                    # Join the segment number to the segment label
                    segment_counter[segment_label] = suffix
                    value = '|'.join([str(suffix)] + segment_values)
                    data['segment'].append(f"{segment_label}-{suffix}")
                    data['field_value'].append(value)
    # Put it all into a dataframe
    df = pd.DataFrame(data)
    return df


# Function to check if a file was modified within the last 24 hours
def find_recently_modified_files(main_directory):
    # Create a list to hold the file paths of the recently modified files
    modified_files = []

    # Iterate through all the subdirectories and files in the main directory
    for root, dirs, files in os.walk(main_directory):
        for file in files:
            file_path = os.path.join(root, file)

            # Get the modification time of the file
            file_mtime = os.path.getmtime(file_path)

            # Convert the modification time to a datetime object
            file_datetime = datetime.fromtimestamp(file_mtime)

            # Get the current date and time 
            current_datetime = datetime.now()

            # Calculate the datetime threshold for the last 24 hours
            threshold_datetime = current_datetime - timedelta(days=1)

            # Check if the file was modified within the last day
            # If yes, then add to our modified_files list
            if file_datetime >= threshold_datetime:
                modified_files.append(file_path)

    return modified_files


# This block identifies the valid extensions
# and determines which messages were sent within the last 24 hours
# Input directory is where raw HL7s are stored
input_directory = 'Input_Files'

# Filter files based on modification time
main_directory = find_recently_modified_files(input_directory)

# Don't include files in the 'Manual Uploads' directory
# because these are duplicates
main_directory = [x for x in main_directory if 'Manual Uploads' not in x]

# Create a temporary directory
# This will hold our files that we append the .txt file extension to
temp_dir = tempfile.mkdtemp()

# Initialize an empty dataframe to store the data from the HL7s
# Each message will be one row
combined_df = pd.DataFrame()

# Initialize an empty dataframe to store errors
errors_df = pd.DataFrame(columns=['file_path', 'error_message'])

# Only read in files that have a .txt file extension
valid_extensions = ['.txt']

# Walk through all modified files
for source_file in main_directory:
    filename = os.path.basename(source_file)
    # Get the new file name with the .txt extension
    new_filename = os.path.splitext(filename)[0] + '.txt'
    # Create the full path of the destination file in the temporary directory
    destination_file = os.path.join(temp_dir, new_filename)
    # Copy the source file to the temporary directory and change its extension to .txt
    shutil.copyfile(source_file, destination_file)

    # Check if the file has a valid file extension
    if any(new_filename.endswith(ext) for ext in valid_extensions):
        try:
            # Read the file and split it into a list of messages based on MSH segment
            # This is for batched messages where a file contains more than one message
            with open(destination_file, 'r', errors='replace') as file:
                hl7_messages_list = file.read().split('MSH')

            # Process each HL7 message separately
            for hl7_message in hl7_messages_list[1:]:  # Skip first empty entry 
                # Add back 'MSH' to each message and split on new line
                hl7_message = 'MSH' + hl7_message
                hl7_message_segments = hl7_message.split('\n')
                
                # Use the process_hl7_messages to process each message
                df = process_hl7_messages(hl7_message_segments)

                # Set 'segment' as the index and transpose the dataframe
                # We want the segments as the columns and each message to be a row
                df = df.set_index('segment').transpose()

                # Reset the index to make df concatenation easier
                df.reset_index(inplace=True, drop=True)
                
                # Make all the columns string-type
                # errored when we didn't do this
                df = df.astype(str)

                # Now we want to split the segments so each component is its own column
                for column in df.columns:
                    # Check if the column contains string values
                    if df[column].dtype == 'O':
                        # Split the values in the column using "|" as the delimiter
                        split_columns = df[column].str.split('|', expand=True)

                        # Add a separator "." to the column names
                        split_columns.columns = split_columns.columns.map(lambda x: f'{column}.{x}')

                        # Concatenate the new columns to the original DataFrame
                        df = pd.concat([df, split_columns], axis=1)

                        # Drop the original column
                        df = df.drop(column, axis=1)

                # Select the columns we want to concatenate in our final df
                selected_columns = ['MSH-1.6',
                                    'MSH-1.9', 
                                    'MSH-1.3', 
                                    'PID-1.22',
                                    'PID-1.10',
                                    'PID-1.5',
                                    'PID-1.7',
                                    'PID-1.8',
                                    'PID-1.11',
                                    'PID-1.13', 
                                    'PID-1.18', 
                                    'PV1-1.2', 
                                    'PV1-1.3', 
                                    'NTE-1.3',
                                    'OBR-1.3',
                                    'ORC-1.3'
                                    ]

                # Add OBX columns matching the pattern OBX-\d.3, OBX-\d.5, and OBX-\d.14
                obx_columns = [col for col in df.columns if re.match(r'OBX-\d{1,2}\.(3|5|14)$', col)]
                selected_columns.extend(obx_columns)

                # Get the columns present in df
                existing_columns = df.columns.tolist()

                # Identify if the dataframe is missing any of the selected_columns
                missing_columns = [col for col in selected_columns if col not in existing_columns]

                # If there are missing columns, create them and fill them with blanks
                # Put them into a dataframe
                blank_data = {col: [''] * len(df) for col in missing_columns}
                blank_df = pd.DataFrame(blank_data)

                # Merge the blank DataFrame with the df DataFrame
                df = pd.concat([df, blank_df], axis=1)

                # Reorder the columns to match the order of selected_columns
                df = df[selected_columns]

                # Reset index before concatenating to avoid non-unique index error
                combined_df.reset_index(drop=True, inplace=True)

                # Combine the message-specific df with the overall df
                combined_df = pd.concat([combined_df, df], ignore_index=True)

        # Exceptions clause to add any errored messages to the errors df
        except UnicodeDecodeError as e:
            # Add the file path and the error message to the dataframe
            errors_df = errors_df.append({'file_path': destination_file, 
                                          'error_message': str(e)}, ignore_index=True)
            print(f"Error processing file: {destination_file}. 
                  Error message: {str(e)}")
            continue
        except FileNotFoundError as e:
            # Add the file path and the error message to the dataframe
            errors_df = errors_df.append({'file_path': destination_file, 
                                          'error_message': str(e)}, ignore_index=True)
            print(f"File not found: {destination_file}. 
                  Error message: {str(e)}")
            continue

# After processing, remove the temporary directory
shutil.rmtree(temp_dir)

# Connect to the database to write combined_df to SQL Server
con = pyodbc.connect('DSN=SQL_Server_Connection')

# Switch Database using SQL commands
cursor = con.cursor()
cursor.execute("USE ELRDQMS")

# Create a connection to SQL Server database using sqlalchemy
engine = create_engine('mssql+pyodbc://', creator=lambda: con)

# Define table name
table_name = 'source_data' 

# Create SQL query to create table if needed
columns = ", ".join([f"{sanitize_column_name(col)} VARCHAR(MAX)" for col in combined_df.columns]) 

# Write the table creation query
create_table_query = f"CREATE TABLE IF NOT EXISTS {table_name} ({columns})"
 
# Execute the create table query
cursor.execute(create_table_query)
 
# Commit the table creation query
con.commit()

# Sanitize the column names to make the data match
combined_df.columns = [sanitize_column_name(col) for col in combined_df.columns]

# Insert DataFrame into SQL Server tabl0
combined_df.to_sql(table_name, con=engine, if_exists='append', index=False)

# Delete duplicates from the SQL Server table
# Fetch column names from the table
cursor.execute(f"SELECT COLUMN_NAME 
               FROM INFORMATION_SCHEMA.COLUMNS 
               WHERE TABLE_NAME = '{table_name}'")

columns = [row.COLUMN_NAME for row in cursor.fetchall()]

# Generate criteria string using all columns
criteria = ','.join(columns)

# Execute SQL query to remove duplicate rows
sql_query = f'''
WITH CTE AS (
    SELECT *, ROW_NUMBER() 
    OVER (PARTITION BY {criteria} 
          ORDER BY (SELECT NULL)) AS rn
    FROM {table_name}
)
DELETE FROM CTE
WHERE rn > 1;
'''

cursor.execute(sql_query)

# Commit changes and close connection
con.commit()

# Close the cursor and connection
cursor.close()
con.close()