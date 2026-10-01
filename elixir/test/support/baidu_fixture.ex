defmodule TeslaMate.BaiduFixture do
  def body do
    %{
      "status" => 0,
      "result" => %{
        "location" => %{"lat" => 39.921, "lng" => 116.410},
        "formatted_address" => "北京市东城区东长安街",
        "addressComponent" => %{
          "country" => "中国",
          "province" => "北京市",
          "city" => "北京市",
          "district" => "东城区",
          "town" => "东华门街道",
          "street" => "东长安街",
          "street_number" => "1号"
        }
      }
    }
  end

  def configure do
    keys = [:geocoding_provider, :baidu_geocoder]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:teslamate, &1)})
    Application.put_env(:teslamate, :geocoding_provider, :baidu)
    Application.put_env(:teslamate, :baidu_geocoder, ak: "fixture-ak", sk: "", timeout: 100)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:teslamate, key, value)
        {key, :error} -> Application.delete_env(:teslamate, key)
      end)
    end)
  end
end
