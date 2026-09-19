"""Reusable Plotly chart builders — consistent styling."""

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
}


def funnel_chart(counts: dict, title: str | None = None) -> go.Figure:
    """Funnel from ordered dict {stage: count}."""
    fig = go.Figure(
        go.Funnel(
            y=list(counts.keys()),
            x=list(counts.values()),
            marker={
                "color": [
                    COLORS["primary"],
                    COLORS["accent"],
                    COLORS["success"],
                    "#6366F1",
                    COLORS["warning"],
                ]
            },
            textinfo="value+percent initial",
        )
    )
    fig.update_layout(
        title=title,
        margin=dict(t=30, b=10, l=10, r=10),
        height=400,
        font={"color": "#0F172A"},
    )
    return fig


def bar_chart(
    df: pd.DataFrame,
    x: str,
    y: str,
    color: str | None = None,
    title: str | None = None,
    horizontal: bool = False,
) -> go.Figure:
    fig = px.bar(
        df,
        x=x if not horizontal else y,
        y=y if not horizontal else x,
        color=color,
        title=title,
        orientation="h" if horizontal else "v",
        color_discrete_sequence=[
            COLORS["primary"],
            COLORS["accent"],
            COLORS["success"],
        ],
    )
    fig.update_layout(margin=dict(t=30, b=10, l=10, r=10), font={"color": "#0F172A"})
    return fig


def line_chart(
    df: pd.DataFrame, x: str, y: str, color: str | None = None, title: str | None = None
) -> go.Figure:
    fig = px.line(
        df,
        x=x,
        y=y,
        color=color,
        title=title,
        markers=True,
        color_discrete_sequence=[COLORS["primary"]],
    )
    fig.update_layout(margin=dict(t=30, b=10, l=10, r=10), font={"color": "#0F172A"})
    return fig
