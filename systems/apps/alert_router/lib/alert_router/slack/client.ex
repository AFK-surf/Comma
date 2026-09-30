defmodule AlertRouter.Slack.Client do
  @moduledoc """
  Narrow Slack Web API boundary owned by Alert Router.

  The official Slack SDKs do not include Elixir, and the repository's existing
  Slack client is coupled to the Salix lease/store runtime. Keeping this
  behaviour JSON-native also lets the router use newly released Block Kit
  blocks without waiting for a community library's structs to catch up.
  """

  @type payload :: %{required(String.t()) => term()}
  @type result ::
          {:ok, %{required(:ts) => String.t()}}
          | {:error, {:rate_limited, pos_integer()}}
          | {:error, {:ambiguous, term()}}
          | {:error, {:retryable, term()}}
          | {:error, {:permanent, term()}}

  @type lookup_result ::
          {:ok, %{required(:complete?) => boolean(), required(:matches) => [map()]}}
          | {:error, {:rate_limited, pos_integer()}}
          | {:error, {:retryable, term()}}
          | {:error, {:permanent, term()}}

  @callback post_root(String.t(), payload()) :: result()
  @callback update_root(String.t(), String.t(), payload()) :: result()
  @callback post_reply(String.t(), String.t(), payload()) :: result()
  @callback permalink(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}

  @callback find_root(String.t(), String.t(), String.t(), pos_integer()) :: lookup_result()

  @callback find_roots(
              String.t(),
              String.t(),
              pos_integer(),
              String.t(),
              String.t()
            ) :: lookup_result()

  @callback find_replies(
              String.t(),
              String.t() | nil,
              String.t(),
              String.t(),
              String.t()
            ) :: lookup_result()
end
