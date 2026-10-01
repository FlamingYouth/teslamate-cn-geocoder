defmodule TeslaMate.Locations.BaiduIntegrationTest do
  use TeslaMate.DataCase, async: false
  import Mock
  import ExUnit.CaptureLog
  alias TeslaMate.{BaiduFixture, Locations, Log, Repo}
  alias TeslaMate.Locations.{Address, Geocoder}
  alias TeslaMate.Log.{Drive, Position}

  setup do
    BaiduFixture.configure()
    :ok
  end

  defp with_geocoder(response, fun) do
    with_mocks [
      {GeocoderMock, [],
       [
         reverse_lookup: fn lat, lon, lang -> Geocoder.reverse_lookup(lat, lon, lang) end,
         details: fn addresses, lang -> Geocoder.details(addresses, lang) end
       ]},
      {Tesla.Adapter.Finch, [], [call: fn env, _ -> response.(env) end]}
    ] do
      fun.()
    end
  end

  defp success(env), do: {:ok, %{env | status: 200, body: BaiduFixture.body()}}
  defp response(env, {:ok, status, body}), do: {:ok, %{env | status: status, body: body}}
  defp response(_env, {:error, _} = error), do: error

  defp car do
    {:ok, car} =
      Log.create_car(%{efficiency: 0.153, eid: 42, vid: 42, model: "M3", vin: "test-only"})

    car
  end

  defp drive do
    {:ok, drive} = Log.start_drive(car())

    for {offset, km, lat} <- [{0, 100, 39.908823}, {60, 101, 39.918823}] do
      {:ok, _} =
        Log.insert_position(drive, %{
          date: DateTime.add(~U[2026-01-01 00:00:00Z], offset),
          latitude: lat,
          longitude: 116.397470,
          odometer: km,
          ideal_battery_range_km: 300,
          rated_battery_range_km: 280
        })
    end

    drive
  end

  test "new addresses persist at WGS84 precision, deduplicate and coexist with OSM" do
    with_geocoder(&success/1, fn ->
      position = %{latitude: 39.908823, longitude: 116.397470}
      assert {:ok, first} = Locations.find_address(position)
      assert {:ok, same} = Locations.find_address(position)
      assert first.id == same.id
      assert first.osm_id > 0
      assert first.latitude == Decimal.new("39.908823")
      assert first.raw["provider"] == "baidu"
      attrs = first |> Map.from_struct() |> Map.drop([:id, :__meta__])
      assert {:ok, legacy} = Locations.create_address(%{attrs | osm_type: "way"})
      refute legacy.id == first.id
      assert Repo.aggregate(Address, :count) == 2
    end)
  end

  test "refresh updates Baidu rows while old OSM rows are unchanged" do
    with_geocoder(&success/1, fn ->
      {:ok, address} = Locations.find_address(%{latitude: 39.908823, longitude: 116.397470})
      {:ok, _} = Locations.update_address(address, %{display_name: "待更新"})
      attrs = address |> Map.from_struct() |> Map.drop([:id, :__meta__])
      {:ok, legacy} = Locations.create_address(%{attrs | osm_type: "way", display_name: "保留旧地址"})
      assert :ok = Locations.refresh_addresses("zh_Hans")
      assert Repo.get!(Address, address.id).display_name == "北京市东城区东长安街"
      assert Repo.get!(Address, legacy.id).display_name == "保留旧地址"
    end)
  end

  test "Nominatim mode skips stored Baidu IDs during refresh and preserves their text" do
    address =
      with_geocoder(&success/1, fn ->
        {:ok, address} = Locations.find_address(%{latitude: 39.908823, longitude: 116.397470})
        address
      end)

    Application.put_env(:teslamate, :geocoding_provider, :nominatim)

    with_geocoder(
      fn env ->
        assert env.url == "https://nominatim.openstreetmap.org/lookup"
        assert env.query[:osm_ids] == ""
        {:ok, %{env | status: 200, body: []}}
      end,
      fn ->
        assert :ok = Locations.refresh_addresses("en")
        unchanged = Repo.get!(Address, address.id)
        assert unchanged.display_name == address.display_name
        assert unchanged.raw == address.raw
      end
    )
  end

  test "refresh failure returns a safe error and preserves existing addresses" do
    address =
      with_geocoder(&success/1, fn ->
        {:ok, address} = Locations.find_address(%{latitude: 39.908823, longitude: 116.397470})
        address
      end)

    with_geocoder(fn _ -> {:error, :timeout} end, fn ->
      capture_log(fn ->
        assert {:error, :baidu_transport_error} = Locations.refresh_addresses("zh_Hans")
      end)

      assert Repo.get!(Address, address.id).display_name == address.display_name
    end)
  end

  test "completed drive has start/end addresses without changes to trajectory or distance" do
    with_geocoder(&success/1, fn ->
      initial = drive()
      assert {:ok, result} = Log.close_drive(initial)
      assert result.distance == 1.0
      assert result.duration_min == 1
      assert result.start_address_id != result.end_address_id
      assert Repo.get!(Address, result.start_address_id).city == "北京市"
      assert Repo.get!(Address, result.end_address_id).city == "北京市"
      positions = Repo.all(from(p in Position, where: p.drive_id == ^result.id, order_by: p.date))
      assert length(positions) == 2
      assert hd(positions).latitude == Decimal.new("39.908823")
      assert List.last(positions).latitude == Decimal.new("39.918823")
    end)
  end

  test "Baidu mode never runs upstream bulk historical address repair" do
    result =
      with_geocoder(fn _ -> {:error, :timeout} end, fn ->
        capture_log(fn ->
          assert {:ok, _} = Log.close_drive(drive())
        end)

        Repo.one!(Drive)
      end)

    state = %TeslaMate.Repair.State{limit: 5000}

    with_mock Tesla.Adapter.Finch, call: fn _, _ -> flunk("unexpected historical lookup") end do
      assert {:noreply, ^state} = TeslaMate.Repair.handle_cast(:repair, state)
    end

    unchanged = Repo.get!(Drive, result.id)
    assert unchanged.start_address_id == nil
    assert unchanged.end_address_id == nil
  end

  for {name, response} <- [
        {"permission", {:ok, 200, %{"status" => 240}}},
        {"quota", {:ok, 200, %{"status" => 302}}},
        {"HTTP", {:ok, 503, "unavailable"}},
        {"timeout", {:error, :timeout}}
      ] do
    test "#{name} failure cannot discard a valid drive or charging record" do
      response = unquote(Macro.escape(response))

      with_geocoder(
        fn env -> response(env, response) end,
        fn ->
          logs =
            capture_log(fn ->
              initial = drive()
              assert {:ok, result} = Log.close_drive(initial)
              assert Repo.get!(Drive, result.id).distance == 1.0
              assert result.start_address_id == nil
              assert result.end_address_id == nil

              assert Repo.aggregate(from(p in Position, where: p.drive_id == ^result.id), :count) ==
                       2

              assert {:ok, charging} =
                       Log.start_charging_process(Repo.get!(Log.Car, result.car_id), %{
                         date: ~U[2026-01-01 01:00:00Z],
                         latitude: 39.908823,
                         longitude: 116.397470
                       })

              assert charging.address_id == nil
              assert charging.position.latitude == Decimal.new("39.908823")
            end)

          refute logs =~ "fixture-ak"
        end
      )
    end
  end
end
