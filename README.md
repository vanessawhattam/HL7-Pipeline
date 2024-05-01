# ELR Data Monitoring System

***

## Introduction

The code contained in this repository is intended to parse electronic lab report (ELR) Health Level 7 (HL7) messages, place them into a dataframe, aggregate the counts of messages by date and facility, and build a model that determines whether the count for a given facility and date is within an expected range. 

The purpose of this project is to better monitor the ELR data feeds received from facilities in Montana. Part 1 of this project will provide insight to whether a hospital is experiencing an increased testing load or if the feed is down. Part 2 of the project will focus on required data element quality and completeness, particularly race and ethnicity. Data from Parts 1 and 2 will be visualized using Tableau or ArcGIS. Part 3 of the project will consist of generating a yearly "report card" for each facility sending ELR data that will detail the quality and completeness of their HL7 messages, in order to support the facility in increasing their data quality. 

More information about HL7 messages can be found on the [HL7 website](https://www.hl7.org/about/index.cfm?ref=nav). 
More information about ELR can be found on the [CDC website](https://www.cdc.gov/elr/about.html).

## Current status

Part 1: ELR data volume - 60% complete
Part 2: Data element quality and completeness - to be intitiated
Part 3: Report cards - to be initiated 

## Files

- `hl7_totext_conversion.ipynb`: This file converts the HL7 messages to *.txt files so that they can be read into a pandas dataframe 
- `time_limiting_function.ipynb`: This file limits the files read to those that were received within the last 24 hours. This reduces the runtime of the script 
- `hl7_dataframe_testing.ipynb`: This file is the one that actually reads in the HL7 messages, parses them into a dataframe, aggregates based on facility and date, and cleans the facility names
- `facility_list.csv`: This file contains a crosswalk for the various facility names sent in the MSH segment of the HL7 messages to a clean version of the facility name. This file is necessary for the code to work, as well as ensuring continuity in feeds as facilities change their names. The file can be found in the shared folder on the network drive: [REDACTED]

## Package dependencies
The original code was written under Python 3.12.0. Required packages include `os`, `re`, `pandas`, `datetime`, `collections`, `statsmodels.api`, `pyodbc`. 

## Usage
Use examples liberally, and show the expected output if you can. It's helpful to have inline the smallest example of usage that you can demonstrate, while providing links to more sophisticated examples if they are too long to reasonably include in the README.

## Support
Code originally written by Vanessa Whattam, MS.
First published: 2023-11-30
Updated: 2023-01-03

## Authors and acknowledgment
Thank you to Jennifer Rico, Jennifer Floch, Danny Power, Neil Squires and Tim Determan for their support on this project. 

## Project status
In development
