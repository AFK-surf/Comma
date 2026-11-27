defmodule SalixAgent.IFC.LocalMetadata do
  @moduledoc "Server-owned fixed local queries that carry no conversation data."

  alias SalixAgent.{SkillProjection, Tools}

  @providers ~w(internal slack feishu lark telegram wechat)
  @tools ~w(help fs.read_file im.provider_apis_list)

  def candidate?(name), do: name in @tools

  def exempt?("help", %{"tool" => tool} = args, _ctx) when map_size(args) == 1,
    do:
      tool == "ifc" or not is_nil(Tools.find_entry(tool)) or
        SalixAgent.Tools.ImRouter.builtin_help?(tool)

  def exempt?("im.provider_apis_list", %{"provider" => provider} = args, _ctx)
      when map_size(args) == 1,
      do: provider in @providers

  def exempt?("fs.read_file", %{"path" => path} = args, ctx) when map_size(args) == 1,
    do: is_binary(path) and SkillProjection.builtin_file?(ctx, path)

  def exempt?(_name, _args, _ctx), do: false
end
