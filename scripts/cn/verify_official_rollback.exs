# Evaluate ONLY against the isolated smoke DB, using official v4.3.0.
import Ecto.Query
alias TeslaMate.Repo
alias TeslaMate.Log.{Drive, Position, ChargingProcess}
alias TeslaMate.Locations.Address
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Repo.start_link()

true =
  Application.get_env(:teslamate, Repo)[:database] in ["codex_cn_smoke", "codex_cn_smoke_amd64"]

drives = Repo.all(from(d in Drive, where: d.id >= 2))
true = length(drives) >= 1
true = Enum.any?(drives, &(&1.start_address_id != nil and &1.end_address_id != nil))

for drive <- drives do
  true = drive.distance == 1.0
  true = Repo.aggregate(from(p in Position, where: p.drive_id == ^drive.id), :count) == 2

  # A real provider quota failure may leave an address nil; the valid drive
  # and its positions must still survive rollback. Do not silently fill it.
  for {id, latitude} <- [
        {drive.start_address_id, "39.908823"},
        {drive.end_address_id, "39.918823"}
      ],
      id != nil do
    address = Repo.get!(Address, id)
    true = address.osm_type == "unknown" and address.osm_id > 0
    true = address.raw["provider"] == "baidu"
    true = address.latitude == Decimal.new(latitude)
  end
end

charging = Repo.all(from(c in ChargingProcess, where: c.id >= 2))
true = length(charging) >= 1

true =
  Enum.all?(charging, fn c -> Repo.get!(Address, c.address_id).raw["provider"] == "baidu" end)

# Official OSM lookup filters these rows out. Its refresh code skips unknown
# rows, so no invented Baidu ID is sent to Nominatim during same-version rollback.
true = Enum.all?(Repo.all(Address), &(&1.osm_type == "unknown"))
IO.puts("official_same_version_reads_baidu_data_and_preserves_trajectory_passed")
