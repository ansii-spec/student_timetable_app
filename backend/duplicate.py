import pandas as pd

# 1. Load your local Excel file
file_path = "final_output.xlsx"
xl = pd.ExcelFile(file_path)

# 2. Loop through each sheet to find duplicates
for sheet in xl.sheet_names:
    df = pd.read_excel(xl, sheet_name=sheet)
    
    # Clean text to remove invisible spaces
    df = df.apply(lambda x: x.str.strip() if x.dtype == "object" else x)
    
    # Find exact duplicate rows across all columns
    duplicate_rows = df[df.duplicated(keep=False)]
    
    if not duplicate_rows.empty:
        print(f"\n⚠️ Duplicates found in sheet: '{sheet}'")
        print(duplicate_rows.to_string())
    else:
        print(f"No duplicates in sheet: '{sheet}'")

