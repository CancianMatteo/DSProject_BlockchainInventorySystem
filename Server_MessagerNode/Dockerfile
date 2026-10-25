FROM elixir:1.18

WORKDIR /app


RUN apt-get update && \
    apt-get install -y build-essential inotify-tools && \
    rm -rf /var/lib/apt/lists/*


RUN mix local.hex --force && \
    mix local.rebar --force


COPY mix.exs ./
RUN mix deps.get
RUN mix deps.compile

COPY . .

RUN mix compile

EXPOSE 4000
EXPOSE 6000

# Port map per node (see PORTS.md at the repo root):
#   4000 - Elixir cluster gossip (Erlang-term, packet:4 framing) – internal only
#   6000 - Elixir simbehaviour HTTP listener – internal only (set via ELIXIR_HTTP_PORT)
# The Python backend owns port 8000 in its own container; this image never
# binds 8000, so sharing the node's IP is conflict-free.
# No ports are exposed because all inter‑process communication uses internal Docker networking.

CMD ["mix", "run", "--no-halt"]
