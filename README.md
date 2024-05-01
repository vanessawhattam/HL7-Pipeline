# ELR Data Monitoring System

![State of Montana Department of Health and Human Services logo, full color](assets/dphhs_logo.png)


## Introduction

The code contained in this repository is intended to parse electronic lab report (ELR) HL7 messages, place them into a dataframe, aggregate the counts of messages by date and facility or disease, and build a model that determines whether the count for a given facility and date is within an expected range. 

The purpose of this project is to better monitor the ELR data feeds received from hospitals across Montana. Increases in the volume of messages from a given hospital can potentially signal an emerging disease outbreak in that region. Additionally, disruptions to the interface between the hospital and the State can delay case investigations and potentially increase disease transmission. Further, the code contains data quality checks to ensure that critical elements of the ELRs are completed, such as patient name, phone number, and laboratory test accession ID. 

More information about HL7 messages can be found on the [HL7 website](https://www.hl7.org/about/index.cfm?ref=nav) and information about ELRs can be found on the [CDC website](https://www.cdc.gov/elr/about.html).

## Getting Started

### Installation 

To get this project up and running, clone the repository to your local machine. Ensure you have Git installed if you intend to clone, otherwise a *.zip file of the files can be downloaded directly from GitHub.

 The examples below provide guidance for using terminal commands to clone the repository to your machine. Extensive documentation on cloning repositories can be found on [GitHub](https://docs.github.com/en/repositories/creating-and-managing-repositories/cloning-a-repository). 

1. Clone this repository to your local machine:
```bash
git clone https://github.com/vanessawhattam/capstone.git
```
2. Navigate to the project directory:
```bash
cd capstone
```

### Usage

1. Run the HL7 parser file
```bash
python RUN_FIRST_hl7_parsing.py
```
The `RUN_FIRST_hl7_parsing.py` file should be run first. The HL7 parser takes HL7 messages in text file-like formats. Ensure that the raw data are placed into a directory called `Input_Files`. Comment out line 91 of the `RUN_FIRST_hl7_parsying.py` if your data pipeline does not include manual uploads of errored messages. This file will parse each HL7 message sent within the last 24 hours, and add it as a row to our combined_df dataframe. This dataframe will then be appended to a SQL Server database table called `source_data`. 

2. Run the Facility Volume modeling file
```bash
Rscript RUN_SECOND_facility_volume_modeling.R
```
The `RUN_SECOND_facility_volume_modeling.R` reads from the SQL Server `source_data` table, groups the data by date and facility, then runs the EWMA model. To run this file, ensure that the `facility_list.csv` file is located in the same directory. Finally, this file runs an initial data quality check on the HL7 messages. The results are written to a CSV file to use in the Tableau dashboard.

3. Run the Condition Volume modeling file
```bash
Rscript RUN_THIRD_covid_volume_model.R
```
The final file in this repository works with the COVID-19 test results. As with `RUN_SECOND_facility_volume_modeling.R`, the `RUN_THIRD_covid_volume_model.R` sources its data from the SQL Server `source_data` table. the Positive COVID-19 tests are identified, grouped together by date and disease (this is for future proofing of adding additional disease) and the anomaly detection model is run. The results are written to a CSV file to use in the Tableau dashboard.


### Package dependencies
The code in the `RUN_FIRST_hl7_parsing.py` file was written under Python 3.12.0. Required packages include: 

* `os`
* `re`
* `shutil`
* `pyodbc`
* `tempfile`
* `numpy`
* `pandas`
* `sqlalchemy` 
* `datetime` 

The code in `RUN_SECOND_facility_volume_modeling.R` and `RUN_THIRD_covid_colume_model.R` were written under R version 4.3.2. The following packages are required: 

* `tidyverse`
* `mosaic`
* `janitor`
* `Metrics`
* `tis`
* `TTR`
* `zoo`
* `forecast`
* `DBI`
* `odbc`

## Support
Code originally written by Vanessa Whattam, MS.\
First published: 2023-11-30\
Updated: 2023-05-03

## Contributions
I am happy to accept contributions to this project. Please send a push request or submit an issue. 

## Acknowledgments
Thank you to Jennifer Rico, Jennifer Floch, Danny Power, Neil Squires and Tim Determan for their support on this project. 

## Project status
In development
