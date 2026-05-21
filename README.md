# HSengRep_DataValid_PP

Cover a function to validate the data from a new area.

## Added design docs
- Chinese solution design: `docs/data_validation_design_zh.md`
- Field dictionary and implementation template: `docs/field_dictionary_zh.md`
- SQL bootstrap schema: `sql/init_validation_schema.sql`

## Current focus
- Raw full-column Excel ingestion + staged upload precheck + standardized warehouse modeling.
- Hybrid validation engine: programmatic precheck at upload time and SQL analytical checks after ingestion.
- Chinese metadata comments on key tables/columns for maintainability.
