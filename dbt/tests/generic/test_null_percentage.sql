{#
  Ported DQ check: null percentage per column, threshold-based. dbt-core's
  built-in `not_null` test is 0%-tolerance only. T-SQL/Synapse has no
  FILTER (WHERE ...) clause (that's Postgres/Presto syntax) -- rewritten as
  SUM(CASE WHEN ... THEN 1 ELSE 0 END), the standard T-SQL equivalent.

  A dbt generic test "fails" when its query returns any rows -- this returns
  exactly one row (with the actual percentage) when the threshold is
  exceeded, and zero rows otherwise.
#}
{% test test_null_percentage(model, column_name, threshold=5) %}

with stats as (
    select
        count(*) as total_rows,
        sum(case when {{ column_name }} is null then 1 else 0 end) as null_rows
    from {{ model }}
)

select
    total_rows,
    null_rows,
    (null_rows * 100.0 / nullif(total_rows, 0)) as null_percentage
from stats
where (null_rows * 100.0 / nullif(total_rows, 0)) > {{ threshold }}

{% endtest %}
