defmodule SystemsRuntime.NetworkGuard.TCP do
  @moduledoc false
  # The node's TCP module while SystemsRuntime.NetworkGuard runs
  # (`:inet_db.set_tcp_module/1`). `:gen_tcp` resolves and connects through
  # it; it checks the host and hands everything to `:inet_tcp`, or to
  # `:inet6_tcp` for an IPv6 address, which `:gen_tcp` also sends here once
  # the default module is not `:inet_tcp`. A socket it opens belongs to those
  # modules, so sends, receives and accepts do not come back here.

  alias SystemsRuntime.NetworkGuard

  def family, do: :inet
  def mask(mask, ip), do: :inet_tcp.mask(mask, ip)
  def parse_address(address), do: :inet_tcp.parse_address(address)
  def getserv(port), do: :inet_tcp.getserv(port)
  def translate_ip(ip), do: :inet_tcp.translate_ip(ip)

  def getaddr(address), do: getaddr(address, :infinity)

  def getaddr(address, timer) do
    with :ok <- NetworkGuard.check_address(address),
         {:ok, ip} <- module(address).getaddr(address, timer) do
      NetworkGuard.resolved_local([ip])
      {:ok, ip}
    end
  end

  def getaddrs(address), do: getaddrs(address, :infinity)

  def getaddrs(address, timer) do
    with :ok <- NetworkGuard.check_address(address),
         {:ok, ips} <- module(address).getaddrs(address, timer) do
      NetworkGuard.resolved_local(ips)
      {:ok, ips}
    end
  end

  def connect(address, port, opts), do: connect(address, port, opts, :infinity)

  def connect(address, port, opts, timeout) do
    with :ok <- NetworkGuard.check_address(address),
         do: module(address).connect(address, port, opts, timeout)
  end

  def listen(port, opts) do
    ip =
      Enum.find_value(opts, fn
        {key, ip} when key in [:ip, :ifaddr] -> ip
        _ -> nil
      end)

    module(ip).listen(port, opts)
  end

  def fdopen(fd, opts), do: :inet_tcp.fdopen(fd, opts)

  def accept(socket), do: :inet_tcp.accept(socket)
  def accept(socket, timeout), do: :inet_tcp.accept(socket, timeout)
  def send(socket, packet), do: :inet_tcp.send(socket, packet)
  def send(socket, packet, opts), do: :inet_tcp.send(socket, packet, opts)
  def recv(socket, length), do: :inet_tcp.recv(socket, length)
  def recv(socket, length, timeout), do: :inet_tcp.recv(socket, length, timeout)
  def unrecv(socket, data), do: :inet_tcp.unrecv(socket, data)
  def shutdown(socket, how), do: :inet_tcp.shutdown(socket, how)
  def close(socket), do: :inet_tcp.close(socket)
  def controlling_process(socket, pid), do: :inet_tcp.controlling_process(socket, pid)

  defp module(ip) when is_tuple(ip) and tuple_size(ip) == 8, do: :inet6_tcp
  defp module(%{family: :inet6}), do: :inet6_tcp
  defp module(_), do: :inet_tcp
end
