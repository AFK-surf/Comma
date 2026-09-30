defmodule SalixWeb.Dashboard.AuthHTML do
  @moduledoc "Login view for the Salix admin dashboard."
  use SalixWeb.Dashboard, :html

  attr(:error, :string, default: nil)

  def login(assigns) do
    ~H"""
    <div class="flex min-h-screen items-center justify-center bg-neutral-50 px-4">
      <div class="w-full max-w-sm">
        <div class="mb-6 flex flex-col items-center text-center">
          <div class="flex h-10 w-10 items-center justify-center rounded-lg bg-brand-500 text-lg font-semibold text-white">
            S
          </div>
          <h1 class="mt-3 text-lg font-semibold text-neutral-900">Salix Admin</h1>
          <p class="mt-1 text-xs text-neutral-500">Sign in with the system admin token.</p>
        </div>

        <div class="rounded-lg border border-neutral-200 bg-white p-5 shadow-subtle">
          <div
            :if={@error}
            class="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-700"
          >
            {@error}
          </div>
          <form action="/dash/session" method="post" class="space-y-3">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <.input
              type="password"
              name="token"
              label="Admin token"
              autocomplete="off"
              autofocus
              placeholder="Paste admin token"
            />
            <.button type="submit" variant="primary" class="w-full">Sign in</.button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
