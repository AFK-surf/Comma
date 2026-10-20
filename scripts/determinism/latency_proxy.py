#!/usr/bin/env python3
"""TCP proxy that delays every chunk it forwards by a random time.

Usage: latency_proxy.py LISTEN_PORT TARGET_HOST:PORT SEED MAX_MS [LISTEN_PORT TARGET SEED MAX_MS ...]

Each direction of each connection forwards its chunks in order; before each
chunk it sleeps uniform(0, MAX_MS) milliseconds drawn from a PRNG seeded
with SEED and the connection's number, the delays are random; the seed sets only their distribution per connection.
"""
import asyncio
import random
import sys


async def pump(reader, writer, rng, max_ms):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            await asyncio.sleep(rng.uniform(0, max_ms) / 1000.0)
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


def serve(listen_port, target, seed, max_ms):
    host, port = target.rsplit(":", 1)
    counter = {"n": 0}

    async def handle(client_reader, client_writer):
        counter["n"] += 1
        n = counter["n"]
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(host, int(port))
        except OSError:
            client_writer.close()
            return
        up = random.Random(f"{seed}:{n}:up")
        down = random.Random(f"{seed}:{n}:down")
        await asyncio.gather(
            pump(client_reader, upstream_writer, up, max_ms),
            pump(upstream_reader, client_writer, down, max_ms),
        )

    return asyncio.start_server(handle, "127.0.0.1", int(listen_port))


async def main(args):
    servers = []
    for i in range(0, len(args), 4):
        listen_port, target, seed, max_ms = args[i : i + 4]
        servers.append(await serve(listen_port, target, seed, float(max_ms)))
    await asyncio.gather(*(s.serve_forever() for s in servers))


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
