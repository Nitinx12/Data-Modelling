-- dbt's default generate_schema_name prefixes target.schema, so a model with
-- +schema: core lands in <target.schema>_core (analytics_core here) instead of
-- core. That splits the dbt mirror away from the hand-built staging/core
-- schemas the pipeline, DQ loops, GX suites and docs all read from — use the
-- configured schema verbatim so `make dbt-build` mirrors into the same
-- tables as `make models`.
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
