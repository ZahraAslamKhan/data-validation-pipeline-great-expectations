import great_expectations as gx
import pandas as pd

clean_df = pd.read_csv("clean_data.csv")
corrupt_df = pd.read_csv("corrupt_data.csv")

context = gx.get_context()

clean_data = gx.from_pandas(clean_df)
corrupt_data = gx.from_pandas(corrupt_df)

clean_data.expect_column_values_to_not_be_null("id")
clean_data.expect_column_values_to_not_be_null("age")

clean_data.expect_column_values_to_be_of_type("age", "int64")

clean_data.expect_column_values_to_be_between("age", min_value=18, max_value=60)

clean_data.expect_column_values_to_be_unique("id")

clean_data.expect_column_mean_to_be_between("salary", min_value=20000, max_value=100000)

print("\n--- CLEAN DATA RESULTS ---")
clean_results = clean_data.validate()
print(clean_results)

print("\n--- CORRUPTED DATA RESULTS ---")
corrupt_results = corrupt_data.validate(expectation_suite=clean_data.get_expectation_suite())
print(corrupt_results)