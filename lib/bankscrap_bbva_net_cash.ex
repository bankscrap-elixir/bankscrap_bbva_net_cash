defmodule BankscrapBbvaNetCash do
  @moduledoc """
  Documentation for Bankscrap adapter for BBVA Net Cash accounts.

  This implementation is based on ruby's adapter:
  https://github.com/bankscrap/bankscrap-bbva-net-cash
  """

  @base_endpoint "https://www.bbvanetcash.mobi"
  @login_endpoint "/DFAUTH/slod_mult_mult/EAILServlet"
  @accounts_endpoint "/SESKYOS/kyos_mult_web_servicios_02/services/rest/CuentasServiceREST/getDatosCuentas"
  @transactions_endpoint "/SESKYOS/kyos_mult_web_servicios_02/services/rest/CuentasServiceREST/getMovimientos"

  alias Bankscrap
  alias Bankscrap.{Session, Account, Transaction}

  def login(user, password, company_code) do
    actual_user = format_user(user, company_code)
    actual_password = String.upcase(password)

    params = [
      {"origen", "pibeemovil"},
      {"eai_tipoCP", "up"},
      {"eai_URLDestino", "success_eail_CAS.jsp"},
      {"eai_user", actual_user},
      {"eai_password", actual_password}
    ]

    Bankscrap.post(@base_endpoint <> @login_endpoint, {:form, params}, request_headers(), nil)
    |> Map.get(:headers)
    |> Session.create_session_from_headers()
    |> Map.put(:data, %{user: actual_user, company_code: company_code})
  end

  def fetch_accounts(session) do
    custom_headers = [
      {"Content-Type", "application/json; charset=UTF-8"},
      {"Contexto", generate_context(session)}
    ]

    params = %{
      "peticionCuentasKYOSPaginadas" => %{
        "favoritos" => false,
        "paginacion" => "0"
      }
    }

    case Bankscrap.post(
           @base_endpoint <> @accounts_endpoint,
           Poison.encode!(params),
           request_headers() ++ custom_headers,
           session
         ) do
      %{status_code: 200, body: body} ->
        body
        |> Poison.decode!()
        |> get_in(["respuestacuentas", "cuentas"])
        |> build_accounts

      _ ->
        []
    end
  end

  def fetch_transactions(session, account, start_date, end_date) do
    headers =
      request_headers() ++
        [
          {"Content-Type", "application/json; charset=UTF-8"},
          {"Contexto", generate_context(session)}
        ]

    params = %{
      "peticionMovimientosKYOS" => %{
        "numAsunto" => account.iban,
        "bancoAsunto" => "BANCO BILBAO VIZCAYA ARGENTARIA S.A",
        "fechaDesde" => Date.to_string(start_date) |> String.replace("-", ""),
        "fechaHasta" => Date.to_string(end_date) |> String.replace("-", ""),
        "concepto" => [],
        "importe_Desde" => "",
        "importe_Hasta" => "",
        "divisa" => "EUR",
        "paginacionTLSMT017" => "N000000000000+0000000000000000000",
        "paginacionTLSMT016" => "N00000000000+0000000000000000",
        "descargaInformes" => false,
        "numElem" => 0,
        "banco" => "1",
        "idioma" => "51",
        "formatoFecha" => "dd\/MM\/yyyy",
        "paginacionMOVDIA" => "1",
        "ultimaFechaPaginacionAnterior" => "",
        "ordenacion" => "DESC"
      }
    }

    session
    |> retrieve_transactions(params, headers)
    |> process_transactions(session, params, headers)
  end

  defp retrieve_transactions(session, params, headers) do
    url = @base_endpoint <> @transactions_endpoint

    case Bankscrap.post(url, Poison.encode!(params), headers, session) do
      %{status_code: 200, body: body} ->
        body
        |> Poison.decode!()
        |> Map.get("respuestamovimientos")

      _ ->
        %{}
    end
  end

  defp process_transactions(%{"movimientos" => transactions} = data, session, params, headers)
       when is_list(transactions) and length(transactions) > 0 do
    processed_transactions = Enum.map(transactions, &build_transaction/1)

    if data["descripcion"] == "More records available" do
      updated_params =
        params
        |> put_in(["peticionMovimientosKYOS", "paginacionMOVDIA"], data["paginacionMOVDIA"])
        |> put_in(["peticionMovimientosKYOS", "paginacionTLSMT016"], data["paginacionTLSMT016"])
        |> put_in(["peticionMovimientosKYOS", "paginacionTLSMT017"], data["paginacionTLSMT017"])

      additional_transactions =
        session
        |> retrieve_transactions(updated_params, headers)
        |> process_transactions(session, updated_params, headers)

      processed_transactions ++ additional_transactions
    else
      processed_transactions
    end
  end

  defp process_transactions(%{"movimientos" => transactions} = _data, _session, _params, _headers)
       when is_map(transactions),
       do: [build_transaction(transactions)]

  defp process_transactions(_, _, _, _), do: []

  defp build_accounts(accounts) when is_list(accounts) do
    Enum.map(accounts, &build_account/1)
  end

  defp build_accounts(accounts) when is_map(accounts), do: build_account(accounts)

  defp build_account(data) do
    %Account{
      id: data["referencia"],
      name: data["empresaDes"],
      available_balance: data["saldoValor"],
      balance: data["saldoContable"],
      currency: data["divisa"],
      iban: data["numeroAsunto"],
      description: "#{data["bancoDes"]} #{data["numeroAsuntoMostrar"]}"
    }
  end

  defp build_transaction(data) do
    %Transaction{
      id: data["codRmsoperS"],
      description: data["concepto"] || data["descConceptoTx"],
      effective_date: parse_date(data["fechaContable"]),
      amount: Money.parse!(data["importe"], data["divisa"]),
      balance: Money.parse!(data["saldoContable"], data["divisa"])
    }
  end

  defp request_headers() do
    user_agent =
      :crypto.strong_rand_bytes(32)
      |> Base.encode16(case: :lower)
      |> String.upcase()
      |> Kernel.<>(";Android;LGE;Nexus 5;1080x1776;Android;5.1.1;BMES;4.4;xxhd")

    [
      {"User-Agent", user_agent},
      {"Accept", "application/json"},
      {"Accept-Charset", "UTF-8"},
      {"Connection", "Keep-Alive"},
      {"Host", "www.bbvanetcash.mobi"}
    ]
  end

  defp format_user(user, company_code) do
    "00230001#{company_code}#{String.upcase(user)}"
  end

  defp generate_context(%Session{data: %{user: user}}) do
    String.trim("""
    {"perfil"=>{"usuario"=>"#{user}", "nombre"=>"", "apellido1"=>"", "apellido2"=>"", "dni"=>"", "cargoFun"=>"", "centroCoste"=>"", "matricula"=>"", "bancoOperativo"=>"", "oficinaOperativa"=>"", "bancoFisico"=>"", "oficinaFisica"=>"", "paisOficina"=>"", "idioma"=>"1", "idiomaIso"=>"1", "divisaBase"=>"ZZZ", "divisaSecundaria"=>"", "xtiOfiFisica"=>"", "xtiOfiOperati"=>"", "listaAutorizaciones"=>["AAAA", "BBBB"]}, "puesto"=>{"puestoLogico"=>"3"}, "transacciones"=>{"canalLlamante"=>"4","medioAcceso"=>"7", "secuencia"=>nil, "servicioProducto"=>"27", "tipoIdentificacionCliente"=>"6", "identificacionCliente"=>"", "modoProceso"=>nil, "autorizacion"=>nil, "origenFisico"=>nil}, "datosTecnicos"=>{"idPeticion"=>nil, "UUAARemitente"=>nil, "usuarioLogico"=>"", "cabecerasHttp"=>{"aap"=>"00000034", "iv-user"=> "#{
      user
    }"}, "codigoCliente"=>"1", "tipoAutenticacion"=>"1", "identificacionCliente"=>"", "tipoIdentificacionCliente"=>"6", "propiedades"=>nil}
    """)
  end

  defp parse_date(value) do
    [day, month, year] =
      value
      |> String.split("/")
      |> Enum.map(&String.to_integer/1)

    Date.from_erl({year, month, day}) |> elem(1)
  end
end
