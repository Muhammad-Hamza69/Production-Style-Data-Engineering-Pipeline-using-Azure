{#
  Ported DQ check: row count >= 10 (was DQ_MIN_ROW_COUNT). Originally used
  dbt_expectations.expect_table_row_count_to_be_between, but that package's
  T-SQL/Synapse dispatch macro generates a query with a syntax error
  ("Incorrect syntax near '='") against this specific adapter -- confirmed
  against a real test run where 2 dbt_expectations-based tests failed while
  every hand-written test passed. Same custom-generic-test pattern as
  test_null_percentage.sql, kept simple and dialect-agnostic on purpose.
#}
{% test test_row_count_between(model, min_value=0, max_value=None) %}

with row_count as (
    select count(*) as n from {{ model }}
)

select n from row_count
where n < {{ min_value }}
{% if max_value is not none %}
   or n > {{ max_value }}
{% endif %}

{% endtest %}
