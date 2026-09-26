#' Shared ggplot2 theme for R analysis charts
#'
#' Provides one consistent look for every chart in the R analysis layer so
#' notebook renders, headless PNGs, and the TeX report all match. The theme
#' object itself carries no colour scales; those are attached by
#' `apply_plot_theme()` so the theme stays composable with `+`.
#'
#' @return A ggplot2 theme object
#' @export
get_plot_theme <- function() {
  ggplot2::theme_minimal() +
    ggplot2::theme(
      panel.grid = ggplot2::element_line(color = "#E0E0E0"),
      panel.border = ggplot2::element_blank(),
      axis.line = ggplot2::element_line(color = "#CCCCCC"),
      axis.text = ggplot2::element_text(size = 11L, color = "#333333"),
      axis.title = ggplot2::element_text(size = 12L, color = "#333333", face = "bold"),
      plot.title = ggplot2::element_text(
        size = 14L, color = "#2C3E50", face = "bold", hjust = 0.5
      ),
      plot.subtitle = ggplot2::element_text(size = 12L, color = "#7F8C8D"),
      plot.caption = ggplot2::element_text(size = 9L, color = "#95A5A6"),
      legend.position = "bottom",
      legend.background = ggplot2::element_rect(color = "#E0E0E0", fill = "#F8F8F8"),
      legend.text = ggplot2::element_text(size = 10L, color = "#333333"),
      legend.title = ggplot2::element_text(size = 11L, color = "#2C3E50", face = "bold"),
      strip.background = ggplot2::element_rect(color = "#E0E0E0", fill = "#F5F5F5"),
      strip.text = ggplot2::element_text(size = 11L, color = "#333333", face = "bold")
    )
}

#' Apply the shared theme and palette to a ggplot object
#'
#' @param plot_obj A ggplot object
#' @return The ggplot object with the shared theme and Set1 palette applied
#' @export
apply_plot_theme <- function(plot_obj) {
  plot_obj +
    get_plot_theme() +
    ggplot2::scale_fill_brewer(palette = "Set1") +
    ggplot2::scale_colour_brewer(palette = "Set1")
}
