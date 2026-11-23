-- BeamNG.drive Vulkan VRAM Leak Fix - Startup Loader
-- Loaded automatically by core_modmanager.initDB right after mods are mounted.
-- Note: BeamNG maps underscores '_' to '/' in extension names, so the extension uses camelCase
-- ("vulkanVramFix" -> lua/ge/extensions/vulkanVramFix.lua).

if setExtensionUnloadMode then
  pcall(setExtensionUnloadMode, "vulkanVramFix", "manual")
end
if extensions and not (extensions.isExtensionLoaded and extensions.isExtensionLoaded("vulkanVramFix")) then
  if extensions.load then
    pcall(extensions.load, "vulkanVramFix")
  end
end
