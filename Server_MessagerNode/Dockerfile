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
EXPOSE 8000

CMD ["mix", "run", "--no-halt"]
