local transform_utils = require "kong.plugins.response-transformer-advanced.transform_utils"

describe("Plugin: response-transformer-advanced (utils)", function()
  describe(".skip_transform", function()
    local skip_transform = transform_utils.skip_transform

    it("doesn't skip any response code if whitelist is nil or empty", function()
      assert.falsy(skip_transform(200, nil))
      assert.falsy(skip_transform(200, {}))
      assert.falsy(skip_transform(400, nil))
      assert.falsy(skip_transform(400, {}))
      assert.falsy(skip_transform(500, nil))
      assert.falsy(skip_transform(500, {}))
    end)

    it("doesn't skip whitelisted codes", function()
      assert.falsy(skip_transform(200, {"200"}))
      assert.falsy(skip_transform(400, {"400"}))
      assert.falsy(skip_transform(500, {"500"}))
    end)

    it("skips non-whitelisted response code", function()
      assert.truthy(skip_transform(200, {"400"}))
      assert.truthy(skip_transform(417, {"400"}))
      assert.truthy(skip_transform(400, {"500"}))
    end)
  end)
end)
