@tool
# @tool надо писать, чтобы не только можно было инстанциировать этот скрипт,
# а еще чтобы инициализировалась статика в нем!
# И не важно, что в родительском классе эта директива уже есть!
extends "_.gd"

const __aseprite_sheet_types_by_sprite_sheet_layout: PackedStringArray = \
	[ "packed", "rows", "columns" ]
const __aseprite_animation_directions: PackedStringArray = \
	[ "forward", "reverse", "pingpong", "pingpong_reverse" ]

var __os_command_project_setting: _ProjectSetting = _ProjectSetting.new(
	"aseprite_command", "", TYPE_STRING, PROPERTY_HINT_NONE,
	"", true, func(v: String): return v.is_empty())

var __os_command_arguments_project_setting: _ProjectSetting = _ProjectSetting.new(
	"aseprite_command_arguments", PackedStringArray(), TYPE_PACKED_STRING_ARRAY, PROPERTY_HINT_NONE,
	"", true, func(v: PackedStringArray): return false)

func _init(editor_file_system: EditorFileSystem) -> void:
	var recognized_extensions: PackedStringArray = ["ase", "aseprite"]
	super("Aseprite", recognized_extensions, [], editor_file_system,
		[__os_command_project_setting, __os_command_arguments_project_setting],
		CustomImageFormatLoaderExtension.new(
			recognized_extensions,
			__os_command_project_setting,
			__os_command_arguments_project_setting,
			_common_temporary_files_directory_path_project_setting))

func _export(res_source_file_path: String, atlas_maker: AtlasMaker, options: Dictionary) -> _Common.ExportResult:
	var result: _Common.ExportResult = _Common.ExportResult.new()

	var os_command_result: _ProjectSetting.Result = __os_command_project_setting.get_value()
	if os_command_result.error:
		result.fail(ERR_UNCONFIGURED, "Unable to get Aseprite Command to export spritesheet", os_command_result)
		return result

	var os_command_arguments_result: _ProjectSetting.Result = __os_command_arguments_project_setting.get_value()
	if os_command_arguments_result.error:
		result.fail(ERR_UNCONFIGURED, "Unable to get Aseprite Command Arguments to export spritesheet", os_command_arguments_result)
		return result

	var temp_dir_path_result: _ProjectSetting.Result = _common_temporary_files_directory_path_project_setting.get_value()
	if temp_dir_path_result.error:
		result.fail(ERR_UNCONFIGURED, "Unable to get Temporary Files Directory Path to export spritesheet", temp_dir_path_result)
		return result

	var png_path: String = temp_dir_path_result.value.path_join("temp.png")
	var global_png_path: String = ProjectSettings.globalize_path(png_path)
	var json_path: String = temp_dir_path_result.value.path_join("temp.json")
	var global_json_path: String = ProjectSettings.globalize_path(json_path)

	var output: Array = []
	var exit_code: int = OS.execute(
		os_command_result.value,
		os_command_arguments_result.value + PackedStringArray([
			"--batch",
			"--format", "json-array",
			"--list-tags",
			"--sheet", global_png_path,
			"--data", global_json_path,
			ProjectSettings.globalize_path(res_source_file_path)]),
		output, true, false)
	if exit_code:
		result.fail(ERR_QUERY_FAILED, "An error occurred while executing the Aseprite command. Process exited with code %s" % [exit_code])
		return result
	var raw_atlas_image: Image = Image.load_from_file(global_png_path)
	DirAccess.remove_absolute(global_png_path)
	var json = JSON.new()
	var err: Error = json.parse(FileAccess.get_file_as_string(global_json_path))
	if err:
		result.fail(ERR_INVALID_DATA, "Unable to parse sprite sheet json data with error %s \"%s\"" % [err, error_string(err)])
		return result
	#DirAccess.remove_absolute(global_json_path)
	var raw_sprite_sheet_data: Dictionary = json.data

	var sprite_sheet_layout: _Common.SpriteSheetLayout = options[_Options.SPRITE_SHEET_LAYOUT]
	var source_image_size: Vector2i = _Common.get_vector2i(
		raw_sprite_sheet_data.frames[0].sourceSize, "w", "h")

	var frames_images_by_indices: Dictionary
	var tags_data: Array = raw_sprite_sheet_data.meta.frameTags
	var frames_data: Array = raw_sprite_sheet_data.frames
	var frames_count: int = frames_data.size()
	if tags_data.is_empty():
		tags_data.push_back({
			name = options[_Options.DEFAULT_ANIMATION_NAME],
			from = 0,
			to = frames_count - 1,
			direction = __aseprite_animation_directions[options[_Options.DEFAULT_ANIMATION_DIRECTION]],
			repeat = options[_Options.DEFAULT_ANIMATION_REPEAT_COUNT]
		})
	var animations_count: int = tags_data.size()
	for tag_data in tags_data:
		for frame_index in range(tag_data.from, tag_data.to + 1):
			if frames_images_by_indices.has(frame_index):
				continue
			var frame_data: Dictionary = frames_data[frame_index]
			frames_images_by_indices[frame_index] = raw_atlas_image.get_region(Rect2i(
				_Common.get_vector2i(frame_data.frame, "x", "y"),
				source_image_size))
	var used_frames_indices: PackedInt32Array = PackedInt32Array(frames_images_by_indices.keys())
	used_frames_indices.sort()
	var used_frames_count: int = used_frames_indices.size()
	var sprite_sheet_frames_indices_by_global_frame_indices: Dictionary
	for sprite_sheet_frame_index in used_frames_indices.size():
		sprite_sheet_frames_indices_by_global_frame_indices[
			used_frames_indices[sprite_sheet_frame_index]] = \
			sprite_sheet_frame_index
	var used_frames_images: Array[Image]
	used_frames_images.resize(used_frames_count)
	for i in used_frames_count:
		used_frames_images[i] = frames_images_by_indices[used_frames_indices[i]]

	var sprite_sheet_builder: _SpriteSheetBuilderBase = _create_sprite_sheet_builder(options)

	var sprite_sheet_building_result: _SpriteSheetBuilderBase.Result = sprite_sheet_builder.build_sprite_sheet(used_frames_images)
	if sprite_sheet_building_result.error:
		result.fail(ERR_BUG, "Sprite sheet building failed", sprite_sheet_building_result)
		return result
	var sprite_sheet: _Common.SpriteSheetInfo = sprite_sheet_building_result.sprite_sheet

	var atlas_making_result: AtlasMaker.Result = atlas_maker \
		.make_atlas(sprite_sheet_building_result.atlas_image)
	if atlas_making_result.error:
		result.fail(ERR_SCRIPT_FAILED, "Unable to make atlas texture from image", atlas_making_result)
		return result
	sprite_sheet.atlas = atlas_making_result.atlas

	var animation_library: _Common.AnimationLibraryInfo = _Common.AnimationLibraryInfo.new()
	var autoplay_animation_name: String = options[_Options.AUTOPLAY_ANIMATION_NAME].strip_edges()

	var all_frames: Array[_Common.FrameInfo]
	all_frames.resize(used_frames_count)
	for animation_index in animations_count:
		var tag_data: Dictionary = tags_data[animation_index]
		var animation = _Common.AnimationInfo.new()
		animation.name = tag_data.name.strip_edges()
		if animation.name.is_empty():
			result.fail(ERR_INVALID_DATA, "A tag with empty name found")
			return result
		if animation.name == autoplay_animation_name:
			animation_library.autoplay_index = animation_index
		animation.direction = __aseprite_animation_directions.find(tag_data.direction)
		animation.repeat_count = tag_data.get("repeat", "0")
		for global_frame_index in range(tag_data.from, tag_data.to + 1):
			var sprite_sheet_frame_index: int = \
				sprite_sheet_frames_indices_by_global_frame_indices[global_frame_index]
			var frame: _Common.FrameInfo = all_frames[sprite_sheet_frame_index]
			if frame == null:
				frame = _Common.FrameInfo.new()
				frame.sprite = sprite_sheet.sprites[sprite_sheet_frame_index]
				frame.duration = frames_data[global_frame_index].duration * 0.001
				all_frames[sprite_sheet_frame_index] = frame
			animation.frames.push_back(frame)
		animation_library.animations.push_back(animation)

	if not autoplay_animation_name.is_empty() and animation_library.autoplay_index < 0:
		push_warning("Autoplay animation name not found: \"%s\". Continuing..." % [autoplay_animation_name])

	result.success(sprite_sheet, animation_library)
	return result

class CustomImageFormatLoaderExtension:
	extends ImageFormatLoaderExtension

	var __recognized_extensions: PackedStringArray
	var __os_command_project_setting: _ProjectSetting
	var __os_command_arguments_project_setting: _ProjectSetting
	var __common_temporary_files_directory_path_project_setting: _ProjectSetting

	func _init(recognized_extensions: PackedStringArray,
		os_command_project_setting: _ProjectSetting,
		os_command_arguments_project_setting: _ProjectSetting,
		common_temporary_files_directory_path_project_setting: _ProjectSetting
		) -> void:
		__recognized_extensions = recognized_extensions
		__os_command_project_setting = os_command_project_setting
		__os_command_arguments_project_setting = os_command_arguments_project_setting
		__common_temporary_files_directory_path_project_setting = \
			common_temporary_files_directory_path_project_setting

	func _get_recognized_extensions() -> PackedStringArray:
		return __recognized_extensions

	func _load_image(image: Image, file_access: FileAccess, flags: int, scale: float) -> Error:
		var global_source_file_path: String = file_access.get_path_absolute()

		var os_command_result: _ProjectSetting.Result = __os_command_project_setting.get_value()
		if os_command_result.error:
			push_error(os_command_result.error_description)
			return os_command_result.error

		var os_command_arguments_result: _ProjectSetting.Result = __os_command_arguments_project_setting.get_value()
		if os_command_arguments_result.error:
			push_error(os_command_arguments_result.error_description)
			return os_command_arguments_result.error

		var temp_dir_path_result: _ProjectSetting.Result = __common_temporary_files_directory_path_project_setting.get_value()
		if temp_dir_path_result.error:
			push_error(temp_dir_path_result.error_description)
			return temp_dir_path_result.error

		var png_path: String = temp_dir_path_result.value.path_join("temp.png")
		var global_png_path: String = ProjectSettings.globalize_path(png_path)
		var json_path: String = temp_dir_path_result.value.path_join("temp.json")
		var global_json_path: String = ProjectSettings.globalize_path(json_path)

		var output: Array = []
		var exit_code: int = OS.execute(
			os_command_result.value,
			os_command_arguments_result.value + PackedStringArray([
				"--batch",
				"--format", "json-array",
				"--list-tags",
				"--sheet", global_png_path,
				"--data", global_json_path,
				global_source_file_path]),
			output, true, false)
		if exit_code:
			push_error("An error occurred while executing the Aseprite command. Process exited with code %s" % [exit_code])
			return ERR_QUERY_FAILED
		var raw_atlas_image: Image = Image.load_from_file(global_png_path)
		DirAccess.remove_absolute(global_png_path)
		var json = JSON.new()
		var err: Error = json.parse(FileAccess.get_file_as_string(global_json_path))
		if err:
			push_error("Unable to parse sprite sheet json data with error %s \"%s\"" % [err, error_string(err)])
			return ERR_INVALID_DATA
		DirAccess.remove_absolute(global_json_path)
		var raw_sprite_sheet_data: Dictionary = json.data

		var source_image_size: Vector2i = _Common.get_vector2i(
			raw_sprite_sheet_data.frames[0].sourceSize, "w", "h")

		image.copy_from(raw_atlas_image.get_region(Rect2i(Vector2i.ZERO, source_image_size)))
		return OK
