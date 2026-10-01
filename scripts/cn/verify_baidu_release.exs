# Run by `bin/teslamate rpc` in the isolated Baidu-mode smoke container.
import Ecto.Query
alias TeslaMate.{Locations, Log, Repo}
alias TeslaMate.Log.{Car, Drive, Position, ChargingProcess}
alias TeslaMate.Locations.Address

true =
  Application.get_env(:teslamate, Repo)[:database] in ["codex_cn_smoke", "codex_cn_smoke_amd64"]

%Drive{start_address_id: nil, end_address_id: nil} = Repo.get!(Drive, 1)
%ChargingProcess{address_id: nil} = Repo.get!(ChargingProcess, 1)
{:noreply, _} = TeslaMate.Repair.handle_cast(:repair, %TeslaMate.Repair.State{limit: 5000})
true = Repo.get!(Drive, 1).start_address_id == nil
true = Repo.get!(ChargingProcess, 1).address_id == nil

car = Repo.get!(Car, 1)
{:ok, drive} = Log.start_drive(car)

for {offset, km, lat} <- [{0, 200, 39.908823}, {60, 201, 39.918823}] do
  {:ok, _} =
    Log.insert_position(drive, %{
      date:
        DateTime.add(~U[2026-01-01 00:00:00Z], offset, :second, Calendar.UTCOnlyTimeZoneDatabase),
      latitude: lat,
      longitude: 116.397470,
      odometer: km,
      ideal_battery_range_km: 300,
      rated_battery_range_km: 280
    })
end

{:ok, completed} = Log.close_drive(drive)
true = completed.distance == 1.0
true = completed.start_address_id != nil and completed.end_address_id != nil
true = completed.start_address_id != completed.end_address_id
positions = Repo.all(from(p in Position, where: p.drive_id == ^completed.id, order_by: p.date))
true = length(positions) == 2
true = hd(positions).latitude == Decimal.new("39.908823")
true = List.last(positions).latitude == Decimal.new("39.918823")
start_address = Repo.get!(Address, completed.start_address_id)
true = start_address.raw["provider"] == "baidu"
true = start_address.city == "北京市"
{:ok, same} = Locations.find_address(hd(positions))
true = same.id == start_address.id

{:ok, charging} =
  Log.start_charging_process(car, %{
    date: ~U[2026-01-01 01:00:00Z],
    latitude: 39.908823,
    longitude: 116.397470
  })

true = charging.address_id == start_address.id
true = charging.position.latitude == Decimal.new("39.908823")
IO.puts("baidu_production_release_persistence_dedup_wgs84_history_guard_passed")
