{#
  Ported DQ check: value range (was check_value_ranges, e.g. views 0-50B).
  Originally used dbt_expectations.expect_column_values_to_be_between --
  see test_row_count_between.sql's header comment for why that package was
  dropped in favor of this hand-written equivalent.
#}
{% test test_value_range(model, column_name, min_value=None, max_value=None) %}

select {{ column_name }}
from {{ model }}
where {{ column_name }} is not null
  and (
    {%- if min_value is not none %} {{ column_name }} < {{ min_value }} {%- endif %}
    {%- if min_value is not none and max_value is not none %} or {%- endif %}
    {%- if max_value is not none %} {{ column_name }} > {{ max_value }} {%- endif %}
  )

{% endtest %}
