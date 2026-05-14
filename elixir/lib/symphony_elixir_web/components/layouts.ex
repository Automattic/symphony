defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  alias SymphonyElixirWeb.StaticAssets

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:dashboard_css_path, StaticAssets.asset_path!("/dashboard.css"))
      |> assign(:phoenix_html_js_path, StaticAssets.asset_path!("/vendor/phoenix_html/phoenix_html.js"))
      |> assign(:phoenix_js_path, StaticAssets.asset_path!("/vendor/phoenix/phoenix.js"))
      |> assign(:phoenix_live_view_js_path, StaticAssets.asset_path!("/vendor/phoenix_live_view/phoenix_live_view.js"))

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer phx-track-static src={@phoenix_html_js_path}></script>
        <script defer phx-track-static src={@phoenix_js_path}></script>
        <script defer phx-track-static src={@phoenix_live_view_js_path}></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            function installRestartAwareReconnect(liveSocket) {
              var reconnectTimer = null;
              var reconnectActive = false;
              var reconnectAttempts = 0;

              function reconnectDelay() {
                return Math.min(30000, Math.round(1000 * Math.pow(1.5, reconnectAttempts)));
              }

              function shouldCancelReconnect(view) {
                return (
                  view &&
                  ((typeof view.isDestroyed === "function" && view.isDestroyed()) ||
                    (typeof view.isConnected === "function" && view.isConnected()))
                );
              }

              function scheduleReconnect(view) {
                clearTimeout(reconnectTimer);

                reconnectTimer = setTimeout(function () {
                  if (shouldCancelReconnect(view)) {
                    reconnectActive = false;
                    reconnectAttempts = 0;
                    return;
                  }

                  reconnectAttempts += 1;

                  if (!liveSocket.isConnected()) {
                    liveSocket.getSocket().connect();
                  }

                  scheduleReconnect(view);
                }, reconnectDelay());
              }

              liveSocket.reloadWithJitter = function (view, log) {
                if (typeof log === "function") log();

                if (!reconnectActive) {
                  reconnectActive = true;
                  reconnectAttempts = 0;
                }

                scheduleReconnect(view);
              };
            }

            var transcriptFilterHook = {
              mounted: function () {
                this.activeFilters = this.initialFilters();
                this.handleFilterClick = function (event) {
                  var button = event.target.closest("[data-transcript-filter]");
                  if (!button || !this.el.contains(button)) return;

                  event.preventDefault();

                  var filter = button.getAttribute("data-transcript-filter");
                  if (filter === "all") {
                    this.activeFilters.clear();
                  } else if (this.activeFilters.has(filter)) {
                    this.activeFilters.delete(filter);
                  } else {
                    this.activeFilters.add(filter);
                  }

                  this.applyFilters();
                }.bind(this);

                this.el.addEventListener("click", this.handleFilterClick);
                this.applyFilters();
              },
              updated: function () {
                this.applyFilters();
              },
              destroyed: function () {
                this.el.removeEventListener("click", this.handleFilterClick);
              },
              filterButtons: function () {
                return Array.from(this.el.querySelectorAll("[data-transcript-filter]"));
              },
              filterKinds: function () {
                return this.filterButtons()
                  .map(function (button) {
                    return button.getAttribute("data-transcript-filter");
                  })
                  .filter(function (filter) {
                    return filter && filter !== "all";
                  });
              },
              initialFilters: function () {
                return new Set(
                  this.filterButtons()
                    .filter(function (button) {
                      return button.getAttribute("aria-pressed") === "true";
                    })
                    .map(function (button) {
                      return button.getAttribute("data-transcript-filter");
                    })
                    .filter(function (filter) {
                      return filter && filter !== "all";
                    })
                );
              },
              applyFilters: function () {
                var events = this.el.querySelector("[data-transcript-events]");
                if (!events) return;

                events.removeAttribute("data-filter-active");
                this.filterKinds().forEach(function (filter) {
                  events.removeAttribute("data-filter-" + filter);
                });

                if (this.activeFilters.size > 0) {
                  events.setAttribute("data-filter-active", "true");
                  this.activeFilters.forEach(function (filter) {
                    events.setAttribute("data-filter-" + filter, "true");
                  });
                }

                this.filterButtons().forEach(function (button) {
                  var filter = button.getAttribute("data-transcript-filter");
                  var pressed =
                    filter === "all" ? this.activeFilters.size === 0 : this.activeFilters.has(filter);

                  button.setAttribute("aria-pressed", pressed ? "true" : "false");
                }, this);
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: {TranscriptFilter: transcriptFilterHook}
            });

            installRestartAwareReconnect(liveSocket);
            liveSocket.connect();

            window.liveSocket = liveSocket;
          });
        </script>
        <link phx-track-static rel="stylesheet" href={@dashboard_css_path} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
