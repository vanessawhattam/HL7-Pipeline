
combine_data <- function(df1, df2) {
  last_obx <- tail(names(df2), 1)
  if (last_obx >= 0) {
    last_obx <- max(as.numeric(gsub("^obx_([0-9]+)_14$", "\\1", last_obx))) + 1
  }
  
  # Generate new columns dynamically and set values to NA
  if (last_obx < 30) {
    missing_obx <- c(last_obx:30)
    
    for(obx in missing_obx) {
      new_cols <- paste0("obx_", obx, "_", c(3, 5, 14))
      df2[, new_cols] <- NA
    }
    
    # Update last_obx to the last value in missing_obx
    last_obx <- max(missing_obx)
  } else {
    # Check for values greater than 30 and drop corresponding columns
    last_obx <- tail(names(df2), 1)
    last_obx <- max(as.numeric(gsub("^obx_([0-9]+)_14$", "\\1", last_obx)))
    
    columns_to_drop <- if (max(as.numeric(gsub("^obx_([0-9]+)_14$", "\\1", last_obx))) > 30) {
      extra_obx_nums <- c(30:last_obx)
      
      columns_to_drop <- list()
      
      # Generate regex patterns and find matching column names for each extra_obx_num
      for (obx_num in extra_obx_nums) {
        # Generate regex pattern for the current obx_num
        regex_pattern <- paste0("^obx_", obx_num, "_(3|5|14)$")
        
        # Find matching column names for the current regex pattern
        matching_cols <- grep(regex_pattern, names(df2), value = TRUE)
        
        # Append the matching columns to columns_to_drop
        columns_to_drop <- c(columns_to_drop, list(matching_cols))
      }
      
      columns_to_keep <- setdiff(names(df2), unlist(columns_to_drop))
      
      # Subset df2 to keep only the columns that are not in columns_to_drop
      df2 <- df2[, columns_to_keep]
    }
  }
  
  # Combine data frames using rbind
  combined_df <- rbind(df1, df2)
}
  

  

  

  
  