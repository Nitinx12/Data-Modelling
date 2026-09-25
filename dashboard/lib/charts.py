"""Reusable Plotly chart builders — one theme, one palette, consistent margins.

Every builder takes a DataFrame produced by `lib.db.run_query` and returns a
`plotly.graph_objects.Figure` so pages only ever call `st.plotly_chart(fig)`.
"""

from __future__ import annotations

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go

COLORS = {
    "primary": "#2563EB",
    "accent": "#0EA5E9",
    "muted": "#94A3B8",
    "success": "#10B981",
    "warning": "#F59E0B",
    "danger": "#EF4444",
    "ink": "#0F172A",
}

# Categorical palette used by every multi-series chart
PALETTE = [
    "#2563EB",
    "#0EA5E9",
    "#10B981",
    "#F59E0B",
    "#8B5CF6",
    "#EC4899",
    "#14B8A6",
    "#EF4444",
    "#64748B",
    "#84CC16",
]

# Sequential palette for heatmaps / treemaps
SEQUENTIAL = [
    "#EFF6FF",
    "#BFDBFE",
    "#93C5FD",
    "#60A5FA",
    "#3B82F6",
    "#1D4ED8",
    "#1E3A8A",
]

_TEMPLATE = "plotly_white"


def _style(fig: go.Figure, title: str | None, height: int = 380) -> go.Figure:
    """Apply the shared theme: white ground, dark ink, tight margins."""
    fig.update_layout(
        template=_TEMPLATE,
        title={"text": title, "x": 0.01, "xanchor": "left", "font": {"size": 15}},
        margin=dict(t=48 if title else 24, b=10, l=10, r=10),
        height=height,
        font={"color": COLORS["ink"], "family": "Inter, sans serif"},
        legend={"orientation": "h", "y": 1.12, "x": 0},
        hovermode="x unified",
    )
    fig.update_xaxes(showgrid=False, zeroline=False)
    fig.update_yaxes(gridcolor="#E2E8F0", zeroline=False)
    return fig


def funnel_chart(counts: dict, title: str | None = None) -> go.Figure:
    """Funnel from an ordered dict {stage: count}."""
    fig = go.Figure(
        go.Funnel(
            y=list(counts.keys()),
            x=list(counts.values()),
            marker={
                "color": [
                    COLORS["primary"],
                    COLORS["accent"],
                    COLORS["success"],
                    "#8B5CF6",
                    COLORS["warning"],
                ]
            },
            textinfo="value+percent initial",
        )
    )
    return _style(fig, title, height=380)


def bar_chart(
    df: pd.DataFrame,
    x: str,
    y: str,
    color: str | None = None,
    title: str | None = None,
    horizontal: bool = False,
    text: str | None = None,
) -> go.Figure:
    fig = px.bar(
        df,
        x=x if not horizontal else y,
        y=y if not horizontal else x,
        color=color,
        title=title,
        orientation="h" if horizontal else "v",
        text=text,
        color_discrete_sequence=PALETTE,
    )
    fig.update_traces(textposition="outside", marker_line_width=0)
    return _style(fig, title, height=380)


def line_chart(
    df: pd.DataFrame,
    x: str,
    y: str,
    color: str | None = None,
    title: str | None = None,
    fill: bool = False,
    range_slider: bool = False,
) -> go.Figure:
    fig = px.line(
        df,
        x=x,
        y=y,
        color=color,
        title=title,
        markers=True,
        color_discrete_sequence=PALETTE,
    )
    if fill and color is None:
        fig.update_traces(fill="tozeroy", fillcolor="rgba(37,99,235,0.12)")
    fig.update_traces(line={"width": 2.5})
    if range_slider:
        fig.update_xaxes(rangeslider={"visible": True}, rangeselector={"buttons": []})
    return _style(fig, title, height=380)


def area_chart(
    df: pd.DataFrame, x: str, y: str, color: str | None = None, title: str | None = None
) -> go.Figure:
    fig = px.area(
        df, x=x, y=y, color=color, title=title, color_discrete_sequence=PALETTE
    )
    fig.update_traces(line={"width": 1.5})
    return _style(fig, title, height=380)


def treemap_chart(
    df: pd.DataFrame,
    path: list[str],
    values: str,
    color: str | None = None,
    title: str | None = None,
) -> go.Figure:
    """Hierarchical share-of-total chart (category → subcategory → …)."""
    fig = px.treemap(
        df,
        path=path,
        values=values,
        color=color or path[0],
        color_discrete_sequence=PALETTE,
        title=title,
    )
    fig.update_traces(
        marker={"line": {"width": 1, "color": "#FFFFFF"}},
        textinfo="label+percent root",
        hovertemplate="%{label}<br>%{value:,.0f}<extra></extra>",
    )
    return _style(fig, title, height=440)


def box_chart(
    df: pd.DataFrame,
    x: str,
    y: str,
    color: str | None = None,
    title: str | None = None,
    points: str = "outliers",
) -> go.Figure:
    """Distribution of a measure across a category — spread, median, outliers."""
    fig = px.box(
        df,
        x=x,
        y=y,
        color=color,
        title=title,
        points=points,
        color_discrete_sequence=PALETTE,
    )
    fig.update_traces(marker={"size": 3}, line={"width": 1.2})
    return _style(fig, title, height=400)


def scatter_chart(
    df: pd.DataFrame,
    x: str,
    y: str,
    size: str | None = None,
    color: str | None = None,
    title: str | None = None,
    hover_data: list[str] | None = None,
    log_x: bool = False,
) -> go.Figure:
    fig = px.scatter(
        df,
        x=x,
        y=y,
        size=size,
        color=color,
        title=title,
        hover_data=hover_data,
        log_x=log_x,
        color_discrete_sequence=PALETTE,
        size_max=46,
    )
    fig.update_traces(marker={"opacity": 0.75, "line": {"width": 0.5}})
    return _style(fig, title, height=400)


def heatmap_chart(
    df: pd.DataFrame,
    title: str | None = None,
    x_title: str | None = None,
    y_title: str | None = None,
    color_continuous: str = "Blues",
) -> go.Figure:
    """Wide DataFrame: index = rows (y), columns = x, values = cell measure."""
    fig = px.imshow(
        df,
        text_auto=".2s",
        aspect="auto",
        color_continuous_scale=color_continuous,
        labels={"color": ""},
        title=title,
    )
    fig.update_xaxes(side="top", title=x_title)
    fig.update_yaxes(title=y_title)
    fig.update_layout(coloraxis_showscale=False)
    return _style(fig, title, height=420)


def sunburst_chart(
    df: pd.DataFrame, path: list[str], values: str, title: str | None = None
) -> go.Figure:
    """Radial share chart: outer ring rolls up from the inner ring."""
    fig = px.sunburst(
        df, path=path, values=values, color=path[0], color_discrete_sequence=PALETTE
    )
    fig.update_traces(
        marker={"line": {"width": 1, "color": "#FFFFFF"}},
        hovertemplate="%{label}<br>%{value:,.0f}<extra></extra>",
    )
    return _style(fig, title, height=440)


def stacked_bar_chart(
    df: pd.DataFrame,
    x: str,
    y: str,
    color: str,
    title: str | None = None,
    barmode: str = "stack",
) -> go.Figure:
    fig = px.bar(
        df,
        x=x,
        y=y,
        color=color,
        title=title,
        barmode=barmode,
        color_discrete_sequence=PALETTE,
    )
    fig.update_layout(barmode=barmode)
    return _style(fig, title, height=380)


def wide(df: pd.DataFrame, index: str, columns: str, values: str) -> pd.DataFrame:
    """Long → wide pivot for heatmaps (index = rows, columns = x)."""
    return (
        df.pivot_table(index=index, columns=columns, values=values, aggfunc="sum")
        .sort_index(ascending=False)
        .fillna(0)
    )
