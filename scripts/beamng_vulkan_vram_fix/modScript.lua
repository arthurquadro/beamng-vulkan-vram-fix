-- BeamNG.drive Vulkan VRAM Leak Fix (v1.1.0) - Startup Loader
-- Loaded automatically by core_modmanager.initDB right after mods are mounted.
-- Note: BeamNG maps underscores '_' to '/' in extension names, so the extension uses camelCase
-- ("vulkanVramFix" -> lua/ge/extensions/vulkanVramFix.lua).

setExtensionUnloadMode("vulkanVramFix", "manual")
if not (extensions.isExtensionLoaded and extensions.isExtensionLoaded("vulkanVramFix")) then
  extensions.load("vulkanVramFix")
end
