defmodule BankscrapBbvaNetCash.MixProject do
  use Mix.Project

  def project do
    [
      app: :bankscrap_bbva_net_cash,
      version: "0.1.0",
      elixir: "~> 1.6-dev",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bankscrap, git: "https://github.com/bankscrap-elixir/bankscrap.git"}
    ]
  end
end
