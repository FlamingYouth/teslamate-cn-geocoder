# Run ONLY with the isolated smoke database and the official v4.3.0 image.
alias TeslaMate.{Log, Repo}
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Repo.start_link()

true =
  Application.get_env(:teslamate, Repo)[:database] in ["codex_cn_smoke", "codex_cn_smoke_amd64"]

car =
  Repo.get_by(Log.Car, vin: "cn-smoke-not-a-real-vin") ||
    with {:ok, car} <-
           Log.create_car(%{
             name: "CN isolated smoke fixture",
             efficiency: 0.153,
             eid: 42,
             vid: 42,
             model: "M3",
             vin: "cn-smoke-not-a-real-vin"
           }),
         do: car

car = Repo.preload(car, :settings)
car.settings |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

drive = Repo.get(Log.Drive, 1) || with {:ok, drive} <- Log.start_drive(car), do: drive

for {offset, km, lat} <- [{0, 100, 39.908823}, {60, 101, 39.918823}] do
  {:ok, _} =
    Log.insert_position(drive, %{
      date:
        DateTime.add(~U[2020-01-01 00:00:00Z], offset, :second, Calendar.UTCOnlyTimeZoneDatabase),
      latitude: lat,
      longitude: 116.397470,
      odometer: km,
      ideal_battery_range_km: 300,
      rated_battery_range_km: 280
    })
end

{:ok, completed} = Log.close_drive(drive, lookup_address: false)
true = completed.distance == 1.0
true = completed.start_address_id == nil and completed.end_address_id == nil

{:ok, _} =
  Log.start_charging_process(
    car,
    %{
      date: ~U[2020-01-01 01:00:00Z],
      latitude: 39.908823,
      longitude: 116.397470
    }, lookup_address: false)

IO.puts("official_legacy_fixtures_saved_without_address_lookup")
