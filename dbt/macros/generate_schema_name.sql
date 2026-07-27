{#
  Standard override, ported unchanged from the AWS project: dbt's default
  generate_schema_name macro concatenates target.schema + '_' +
  custom_schema_name, which is wrong here -- each model's +schema config in
  dbt_project.yml is already a literal Synapse SQL schema name ("curated",
  "enriched"), not a suffix. Returning it directly is the well-known
  pattern for projects that map dbt "schemas" onto multiple real schemas
  rather than one schema-per-target.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
