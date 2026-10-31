defmodule InventoryNode.MixProject do
  use Mix.Project

  def project do
    [
      app: :inventory_node,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # :public_key/:ssl are required by :httpc even for plain HTTP requests,
      # because it computes TLS options by default before every request.
      extra_applications: [:inets, :ssl, :public_key, :logger],
      mod: {InventoryNode.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    []
  end
end
