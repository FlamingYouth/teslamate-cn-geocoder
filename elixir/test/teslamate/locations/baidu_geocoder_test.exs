defmodule TeslaMate.Locations.BaiduGeocoderTest do
  use ExUnit.Case, async: false
  import Mock
  import ExUnit.CaptureLog
  alias TeslaMate.Locations.{Address, Geocoder}
  alias TeslaMate.Locations.Geocoder.Baidu
  alias TeslaMate.BaiduFixture

  setup do
    BaiduFixture.configure()
    :ok
  end

  test "official SN vector, UTF8 encoding and parameter order" do
    assert Baidu.signature(
             "/geocoder/v2/",
             [address: "百度大厦", output: "json", ak: "yourak"],
             "yoursk"
           ) == "7de5a22212ffaa9e326444c75a58f9a0"
  end

  test "provider routing, latitude/longitude order and no BD09 coordinate persistence" do
    with_mock Tesla.Adapter.Finch,
      call: fn env, opts ->
        uri = URI.parse(env.url)
        assert uri.scheme == "https"
        assert uri.host == "api.map.baidu.com"
        assert uri.path == "/reverse_geocoding/v3/"
        query = URI.decode_query(uri.query)
        assert query["location"] == "39.908823,116.397470"
        assert query["coordtype"] == "wgs84ll"
        assert query["output"] == "json"
        assert query["ak"] == "fixture-ak"
        assert query["sn"] == nil
        assert opts[:receive_timeout] == 100
        assert opts[:pool_timeout] == 100
        {:ok, %{env | status: 200, body: BaiduFixture.body()}}
      end do
      assert {:ok, attrs} = Geocoder.reverse_lookup("39.908823", "116.397470", "en")
      assert attrs.latitude == Decimal.new("39.908823")
      assert attrs.longitude == Decimal.new("116.397470")
      assert attrs.city == "北京市"
      assert attrs.county == "东城区"
      assert attrs.road == "东长安街"
      assert attrs.house_number == "1号"
      assert attrs.display_name == "北京市东城区东长安街"
      assert attrs.osm_type == "unknown"
      assert attrs.osm_id > 0
      assert attrs.raw["provider"] == "baidu"
      refute Map.has_key?(attrs.raw, "location")
    end
  end

  test "SN request matches the exact encoded query and SN comes last" do
    Application.put_env(:teslamate, :baidu_geocoder, ak: "fixture-ak", sk: "fixture-sk")

    with_mock Tesla.Adapter.Finch,
      call: fn env, _opts ->
        uri = URI.parse(env.url)
        pairs = URI.query_decoder(uri.query) |> Enum.to_list()
        assert {"sn", sn} = List.last(pairs)
        assert sn == Baidu.signature(uri.path, Enum.drop(pairs, -1), "fixture-sk")
        {:ok, %{env | status: 200, body: BaiduFixture.body()}}
      end do
      assert {:ok, _} = Baidu.reverse_lookup(39.908823, 116.397470)
    end
  end

  test "stable IDs follow DB precision and never collide with the unknown sentinel" do
    with_mock Tesla.Adapter.Finch,
      call: fn env, _ -> {:ok, %{env | status: 200, body: BaiduFixture.body()}} end do
      assert {:ok, a} = Baidu.reverse_lookup("39.9088231", "116.3974701")
      assert {:ok, b} = Baidu.reverse_lookup(Decimal.new("39.908823"), 116.397470)
      assert a.osm_id == b.osm_id
      assert {:ok, adjacent} = Baidu.reverse_lookup("39.908824", "116.397470")
      refute adjacent.osm_id == a.osm_id
      assert {:ok, low} = Baidu.reverse_lookup(-90, -180)
      assert low.osm_id == 1
      assert {:ok, high} = Baidu.reverse_lookup(90, 180)
      assert high.osm_id < 9_223_372_036_854_775_807
      assert {:ok, zero} = Baidu.reverse_lookup(0, 0)
      assert zero.osm_id > 0
    end
  end

  for {lat, lon} <- [
        {nil, 116},
        {39, nil},
        {"not-a-number", 116},
        {"39junk", 116},
        {91, 116},
        {-91, 116},
        {39, 181},
        {39, -181},
        {"NaN", 116},
        {"Infinity", 116}
      ] do
    test "invalid coordinates #{inspect({lat, lon})} never make a request" do
      with_mock Tesla.Adapter.Finch, call: fn _, _ -> flunk("unexpected request") end do
        assert {:error, :baidu_invalid_coordinates} =
                 Baidu.reverse_lookup(unquote(lat), unquote(lon))
      end
    end
  end

  test "missing AK never makes a request" do
    Application.put_env(:teslamate, :baidu_geocoder, [])

    with_mock Tesla.Adapter.Finch, call: fn _, _ -> flunk("unexpected request") end do
      assert {:error, :baidu_missing_ak} = Baidu.reverse_lookup(39, 116)
    end
  end

  for code <- [3, 4, 5, 200, 201, 203, 210, 211, 240, 302, 401] do
    test "API status #{code} is sanitized; no credentials or OSM fallback" do
      with_mock Tesla.Adapter.Finch,
        call: fn env, _ ->
          assert URI.parse(env.url).host == "api.map.baidu.com"
          {:ok, %{env | status: 200, body: %{"status" => unquote(code), "message" => env.url}}}
        end do
        log =
          capture_log(fn ->
            assert {:error, {:baidu_api_status, unquote(code)}} = Baidu.reverse_lookup(39, 116)
          end)

        refute log =~ "fixture-ak"
      end
    end
  end

  for body <- [
        nil,
        "broken",
        %{},
        %{"status" => 0},
        %{"status" => 0, "result" => %{}},
        %{"status" => 0, "result" => %{"formatted_address" => " "}},
        %{"status" => 0, "result" => %{"formatted_address" => "ok", "addressComponent" => []}}
      ] do
    test "malformed body #{inspect(body)} returns a safe error" do
      with_mock Tesla.Adapter.Finch,
        call: fn env, _ -> {:ok, %{env | status: 200, body: unquote(Macro.escape(body))}} end do
        assert {:error, :baidu_invalid_response} = Baidu.reverse_lookup(39, 116)
      end
    end
  end

  test "HTTP and transport errors cannot leak request URLs" do
    with_mock Tesla.Adapter.Finch,
      call: fn env, _ -> {:ok, %{env | status: 403, body: env.url}} end do
      assert {:error, {:baidu_http_status, 403}} = Baidu.reverse_lookup(39, 116)
    end

    with_mock Tesla.Adapter.Finch, call: fn env, _ -> {:error, {:timeout, env.url}} end do
      assert {:error, :baidu_transport_error} = Baidu.reverse_lookup(39, 116)
    end
  end

  test "legacy OSM and sentinel rows are preserved without requests" do
    legacy = %Address{osm_type: "way", osm_id: 42, display_name: "旧地址"}
    sentinel = %Address{osm_type: "unknown", osm_id: 0, display_name: "Unknown"}

    with_mock Tesla.Adapter.Finch, call: fn _, _ -> flunk("unexpected request") end do
      assert {:ok, attrs} = Baidu.details([legacy, sentinel])
      assert Enum.find(attrs, &(&1.osm_id == 42)).display_name == "旧地址"
      assert Enum.find(attrs, &(&1.osm_id == 0)).display_name == "Unknown"
    end
  end

  test "field lengths fit the existing schema and arbitrary result fields are dropped" do
    body =
      BaiduFixture.body()
      |> put_in(["result", "formatted_address"], String.duplicate("中", 600))
      |> put_in(["result", "addressComponent", "street"], String.duplicate("路", 300))
      |> put_in(["result", "echo_request"], "fixture-ak")

    with_mock Tesla.Adapter.Finch,
      call: fn env, _ -> {:ok, %{env | status: 200, body: body}} end do
      assert {:ok, attrs} = Baidu.reverse_lookup(39, 116)
      assert String.length(attrs.display_name) == 512
      assert String.length(attrs.road) == 255
      refute inspect(attrs.raw) =~ "fixture-ak"
    end
  end

  test "real Finch HTTP transport: success, invalid JSON, HTTP 403 and read timeout" do
    start_supervised!({Finch, name: TeslaMate.HTTP})
    Application.put_env(:teslamate, :baidu_geocoder, ak: "fixture-ak", timeout: 500)

    for {response, delay, expected} <- [
          {Jason.encode!(BaiduFixture.body()), 0, :ok},
          {"not-json", 0, :baidu_transport_error},
          {Jason.encode!("forbidden"), 0, {:baidu_http_status, 403}},
          {Jason.encode!(BaiduFixture.body()), 2000, :baidu_transport_error}
        ] do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(socket)
      owner = self()
      status = if expected == {:baidu_http_status, 403}, do: "403 Forbidden", else: "200 OK"

      server =
        spawn(fn ->
          with {:ok, client} <- :gen_tcp.accept(socket, 2000),
               {:ok, request} <- :gen_tcp.recv(client, 0, 2000) do
            send(owner, {:http_request, request})
            Process.sleep(delay)

            :gen_tcp.send(
              client,
              "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n#{response}"
            )

            :gen_tcp.close(client)
          end
        end)

      try do
        with_mock Tesla.Adapter.Finch, [:passthrough],
          call: fn env, opts ->
            uri = URI.parse(env.url)
            rewritten = "http://127.0.0.1:#{port}#{uri.path}?#{uri.query}"
            :meck.passthrough([%{env | url: rewritten}, opts])
          end do
          result = Baidu.reverse_lookup(39, 116)

          case expected do
            :ok -> assert {:ok, %{city: "北京市"}} = result
            reason -> assert {:error, ^reason} = result
          end

          assert_receive {:http_request, request}, 2000
          assert request =~ "coordtype=wgs84ll"
        end
      after
        :gen_tcp.close(socket)
        Process.exit(server, :kill)
      end
    end
  end
end
