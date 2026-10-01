defmodule TeslaMate.Locations.Geocoder.Baidu do
  @moduledoc """
  Optional Baidu V3 reverse geocoding. Input and stored coordinates remain WGS84.
  No schema changes, historical backfill, or implicit Nominatim fallback.
  """

  alias TeslaMate.Locations.Address

  @origin "https://api.map.baidu.com"
  @path "/reverse_geocoding/v3/"

  def reverse_lookup(latitude, longitude) do
    config = Application.get_env(:teslamate, :baidu_geocoder, [])

    with {:ok, lat} <- coordinate(latitude, 90),
         {:ok, lon} <- coordinate(longitude, 180),
         ak when is_binary(ak) and ak != "" <- Keyword.get(config, :ak) do
      params = [
        ak: ak,
        output: "json",
        coordtype: "wgs84ll",
        location: "#{Decimal.to_string(lat, :normal)},#{Decimal.to_string(lon, :normal)}",
        extensions_poi: "0"
      ]

      params =
        case Keyword.get(config, :sk, "") do
          sk when is_binary(sk) and sk != "" -> params ++ [sn: signature(@path, params, sk)]
          _ -> params
        end

      # Construct the query once: the order/encoding must match the SN signature.
      url = @origin <> @path <> "?" <> URI.encode_query(params)
      timeout = Keyword.get(config, :timeout, 5000)

      # Deliberately no request-logging middleware (the URL contains the AK/SN).
      client =
        Tesla.client(
          [Tesla.Middleware.JSON],
          {Tesla.Adapter.Finch,
           name: TeslaMate.HTTP, receive_timeout: timeout, pool_timeout: timeout}
        )

      case Tesla.get(client, url) do
        {:ok, %Tesla.Env{status: 200, body: body}} -> into_address(body, lat, lon)
        {:ok, %Tesla.Env{status: status}} -> {:error, {:baidu_http_status, status}}
        {:error, _} -> {:error, :baidu_transport_error}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :baidu_missing_ak}
    end
  end

  def details(addresses) do
    Enum.reduce_while(addresses, {:ok, []}, fn address, {:ok, acc} ->
      case address do
        %Address{osm_type: "unknown", osm_id: id, raw: %{"provider" => "baidu"}}
        when id > 0 ->
          case reverse_lookup(address.latitude, address.longitude) do
            {:ok, attrs} ->
              attrs = Map.merge(attrs, %{osm_id: id, osm_type: "unknown"})
              {:cont, {:ok, [attrs | acc]}}

            {:error, _} = error ->
              {:halt, error}
          end

        # Preserve legacy OSM/unknown rows; never silently migrate old addresses.
        %Address{} ->
          {:cont, {:ok, [Map.from_struct(address) | acc]}}
      end
    end)
  end

  @doc false
  def signature(path, params, sk) do
    payload = URI.encode_www_form(path <> "?" <> URI.encode_query(params) <> sk)
    :crypto.hash(:md5, payload) |> Base.encode16(case: :lower)
  end

  defp coordinate(value, limit) do
    decimal =
      case value do
        %Decimal{} ->
          value

        value when is_integer(value) ->
          Decimal.new(value)

        value when is_float(value) ->
          Decimal.from_float(value)

        value when is_binary(value) ->
          case Decimal.parse(value) do
            {decimal, ""} -> decimal
            _ -> nil
          end

        _ ->
          nil
      end

    case decimal do
      %Decimal{coef: coef} when is_integer(coef) ->
        if Decimal.compare(decimal, -limit) != :lt and Decimal.compare(decimal, limit) != :gt do
          {:ok, Decimal.round(decimal, 6)}
        else
          {:error, :baidu_invalid_coordinates}
        end

      _ ->
        {:error, :baidu_invalid_coordinates}
    end
  end

  defp into_address(%{"status" => 0, "result" => result}, lat, lon) when is_map(result) do
    component = Map.get(result, "addressComponent", %{})
    display_name = text(result["formatted_address"], 512)

    if is_map(component) and display_name != nil do
      # A non-OSM row uses the existing "unknown" namespace, with a distinct
      # positive ID. Official v4.3.0 then safely skips it during OSM refresh.
      # This bijection of 6-decimal WGS84 coordinates fits PostgreSQL bigint.
      lat_index = lat |> Decimal.mult(1_000_000) |> Decimal.to_integer()
      lon_index = lon |> Decimal.mult(1_000_000) |> Decimal.to_integer()
      id = (lat_index + 90_000_000) * 360_000_001 + lon_index + 180_000_000 + 1

      attrs = %{
        osm_type: "unknown",
        osm_id: id,
        latitude: lat,
        longitude: lon,
        display_name: display_name,
        name: text(component["street"]),
        house_number: text(component["street_number"]),
        road: text(component["street"]),
        neighbourhood: text(component["town"]),
        city: text(component["city"]) || text(component["province"]),
        county: text(component["district"]),
        state: text(component["province"]),
        country: text(component["country"]),
        postcode: nil,
        state_district: nil
      }

      # Only whitelist parsed address fields. No request parameters, credentials,
      # provider-returned BD09 coordinates, or arbitrary response fields persist.
      raw =
        attrs
        |> Map.drop([:osm_id, :osm_type, :latitude, :longitude])
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.merge(%{"provider" => "baidu", "input_coordtype" => "wgs84ll"})

      {:ok, Map.put(attrs, :raw, raw)}
    else
      {:error, :baidu_invalid_response}
    end
  end

  defp into_address(%{"status" => status}, _, _) when is_integer(status) and status != 0,
    do: {:error, {:baidu_api_status, status}}

  defp into_address(_, _, _), do: {:error, :baidu_invalid_response}

  defp text(value, limit \\ 255)

  defp text(value, limit) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> String.slice(value, 0, limit)
    end
  end

  defp text(_, _), do: nil
end
