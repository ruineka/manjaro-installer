extends Resource
class_name Installer

signal bootstrap_progressed(percent: float)
signal dd_progressed(percent: float)
signal dd_status(status: bool)
signal install_progressed(percent: float)
signal repair_progressed(percent: float)

const MOUNT_PATH := "/tmp/frzr_root"
const USER := "gamer"
const SYS_CONN_DIR := "/etc/NetworkManager/system-connections"

enum ERROR {
	OK = 0,
	FAILED,
	CANT_CREATE,
	PARTITIONING_FAILED,
	CLEANING_FAILED,
}

var last_error := ""
var target := "stable"
var shared_thread: SharedThread
var underlay_log: FileAccess
var underlay_process: InteractiveProcess

var flash_finished = false
var flash_path = ""

var logger := Log.get_logger("Main", Log.LEVEL.INFO)

## Return the available disks
func get_available_disks() -> Array[Disk]:
	var disks: Array[Disk] = []
	var output := []
	if OS.execute("lsblk", ["--list", "-n", "-o", "name,type,size,model"], output) != OK:
		print("Unable to read devices: ", output[0])
		return disks
	var stdout := output[0] as String

	# Parse the output
	for line in stdout.split("\n"):
		if not line.contains("disk"):
			continue
		var parts := line.split(" ", false, 3)
		if parts.size() < 4:
			continue
		var disk := Disk.new()
		disk.name = parts[0]
		disk.path = "/dev/" + disk.name
		disk.size = parts[2]
		disk.model = parts[3]
		disk.install_found = has_existing_install(disk.name)
		disks.append(disk)
	
	return disks


## Returns true if the block device at the given path has an existing frzr install 
func has_existing_install(path: String) -> bool:
	var output := []
	if OS.execute("lsblk", ["-o", "label", path], output) != OK:
		print("Unable to read label from path " + path + ": " + output[0])
		return false
	var stdout := output[0] as String
	
	return stdout.contains("frzr_efi")


## Returns the path to the partitions on the given disk.
## E.g. ["/dev/sda1", "/dev/sda2"]
func get_partitions(disk: Disk) -> PackedStringArray:
	var partitions := PackedStringArray()
	var output := []
	if OS.execute("lsblk", ["--list", "-n", "-o", "name,type", disk.path], output) != OK:
		push_error("Unable to read partitions on disk: ", output[0])
		return partitions
	var stdout := output[0] as String
	
	for line in stdout.split("\n"):
		if line.contains("disk") or not line.contains("part"):
			continue
		var parts := line.split(" ", false, 2)
		partitions.append("/dev/" + parts[0])
		
	return partitions


## Repair the installation
## https://github.com/ChimeraOS/frzr/blob/master/frzr-bootstrap
func repair_install(disk: Disk) -> ERROR:
	if DirAccess.make_dir_recursive_absolute(MOUNT_PATH) != OK:
		push_error("Failed to create mount path: " + MOUNT_PATH)
		return ERROR.CANT_CREATE
	repair_progressed.emit(0.1)

	# Mount the btrfs filesystem
	var partitions := get_partitions(disk)
	if partitions.size() != 2:
		push_error("Unable to find install partitions")
		return ERROR.PARTITIONING_FAILED
	var boot_efi := partitions[0]
	var install_mount := partitions[1]
	repair_progressed.emit(0.2)
	
	var mount_task := Command.new("mount", [install_mount, MOUNT_PATH])
	if await mount_task.execute() != OK:
		return ERROR.PARTITIONING_FAILED
	repair_progressed.emit(0.3)
	
	var mount_efi_task := Command.new("mount", ["-t", "vfat", boot_efi, MOUNT_PATH + "/boot/"])
	if await mount_efi_task.execute() != OK:
		return ERROR.PARTITIONING_FAILED
	repair_progressed.emit(0.4)

	var clean_boot_task := Command.new("bash", ["-c", "rm -rf " + MOUNT_PATH + "/boot/*"])
	if await clean_boot_task.execute() != OK:
		return ERROR.CLEANING_FAILED
	repair_progressed.emit(0.5)

	var bootctl_task := Command.new("bootctl", ["--esp-path=" + MOUNT_PATH + "/boot/", "install"])
	if await bootctl_task.execute() != OK:
		return ERROR.PARTITIONING_FAILED
	repair_progressed.emit(0.6)
	
	# Delete the subvolume
	await Command.new("btrfs", ["subvolume", "delete", MOUNT_PATH + "/deployments/*"]).execute()
	repair_progressed.emit(0.9)
	
	var clean_etc_task := Command.new("bash", ["-c", "rm -rf " + MOUNT_PATH + "/etc/*"])
	if await clean_etc_task.execute() != OK:
		return ERROR.CLEANING_FAILED
	repair_progressed.emit(1.0)
	
	return ERROR.OK
func _start_underlay_process(args: Array, log_path: String) -> void:
	# Start the shared thread we use for logging.
	shared_thread = SharedThread.new()
	shared_thread.start()

	# Setup logging
	underlay_log = FileAccess.open(log_path, FileAccess.WRITE)
	var error := underlay_log.get_open_error()
	if error != OK:
		logger.warn("Got error opening log file.")
	else:
		logger.info("Started logging underlay process at " + log_path)
	var command: String = args[0]
	args.remove_at(0)
	underlay_process = InteractiveProcess.new(command, args)
	if underlay_process.start() != OK:
		logger.error("Failed to start child process.")
		return
	var logger_func := func(delta: float):
		underlay_process.output_to_log_file(underlay_log)
	#shared_thread.add_process(logger_func)
func _emit_flash_exit(status: bool):
	emit_signal("dd_status", status)
func dd_flash():
	var flashing = true
	var stdout = ""
	var progress
	while flashing:
		stdout = underlay_process.read()
		if stdout != "":
			print(stdout)
		# Check for any errors
		var regex_err = RegEx.new()
		regex_err.compile("command failed")
		var err = regex_err.search(stdout)
		if err:
			print("The process ended unexpectedly")
			call_deferred("_emit_flash_exit", false)
			flashing = false
			break
		# Search patterns for output percentage
		var regex = RegEx.new()
		regex.compile("[0-9]+$")
		var result = regex.search(stdout)

		if result:
			progress = result.get_string()
			dd_progressed.emit(float(progress) / 100)
		if not underlay_process.is_running():
			flashing = false
			call_deferred("_emit_flash_exit", true)
func dd_image(to_disk: Disk) -> void:
	var image_path = "/home/ruineka/Downloads/chimeraos-2024.01.21-x86_64.iso"
	var size_command = "$(stat -c %s " + image_path + " | awk '{print int($1 / 1024 / 1024)}')"
	var fake_path = "/dev/null" # used for debugging
	var bash_command = [
	"dd if=" + image_path + " | pv -s " + size_command + "M -n | dd of=" + fake_path + " bs=100k || echo 'command failed'"
	];

	var log_path := OS.get_environment("HOME") + "/.underlay-stdout.log"
	_start_underlay_process(["bash","-c"] + bash_command, log_path)
	flash_path = to_disk.path
	# Run dd flash on it's own thread
	shared_thread.exec(dd_flash)
	return
## Bootstrap the given disk
## https://github.com/ChimeraOS/frzr/blob/master/frzr-bootstrap
func bootstrap(to_disk: Disk) -> ERROR:
	if DirAccess.make_dir_recursive_absolute(MOUNT_PATH) != OK:
		last_error = "Failed to create mount path: " + MOUNT_PATH
		return ERROR.CANT_CREATE
	bootstrap_progressed.emit(0.1)
	
	# Create partition table
	var parted_task := Command.new("parted")
	parted_task.args = [
		"--script", to_disk.path,
		"mklabel", "gpt",
		"mkpart", "primary", "fat32", "1MiB", "512MiB",
		"set", "1", "esp", "on",
		"mkpart", "primary", "512MiB", "100%"
	]
	if await parted_task.execute() != OK:
		last_error = "Unable to create partition table"
		return ERROR.PARTITIONING_FAILED
	bootstrap_progressed.emit(0.2)

	# Create and mount the btrfs filesystem
	var partitions := get_partitions(to_disk)
	if partitions.size() != 2:
		last_error = "Unable to find created partitions on disk"
		return ERROR.PARTITIONING_FAILED
	var part1 := partitions[0]
	var part2 := partitions[1]
	
	var mkbtrfs_task := Command.new("mkfs.btrfs", ["-L", "frzr_root", "-f", part2])
	if await mkbtrfs_task.execute() != OK:
		last_error = "Unable to create btrfs filesystem on " + part2
		return ERROR.PARTITIONING_FAILED
	bootstrap_progressed.emit(0.4)
	
	var mntbtrfs_task := Command.new("mount", ["-t", "btrfs", "-o", "nodatacow", part2, MOUNT_PATH])
	if await mntbtrfs_task.execute() != OK:
		last_error = "Unable to mount " + part2 + " on " + MOUNT_PATH
		return ERROR.PARTITIONING_FAILED
	bootstrap_progressed.emit(0.6)
	
	var volume1_task := Command.new("btrfs", ["subvolume", "create", MOUNT_PATH + "/var"])
	if await volume1_task.execute() != OK:
		last_error = "Unable to create subvolume at: " + MOUNT_PATH + "/var"
		return ERROR.PARTITIONING_FAILED
	bootstrap_progressed.emit(0.7)

	var volume2_task := Command.new("btrfs", ["subvolume", "create", MOUNT_PATH + "/home"])
	if await volume2_task.execute() != OK:
		last_error = "Unable to create subvolume at: " + MOUNT_PATH + "/home"
		return ERROR.PARTITIONING_FAILED
	bootstrap_progressed.emit(0.8)
	
	if DirAccess.make_dir_recursive_absolute(MOUNT_PATH + "/home/" + USER) != OK:
		last_error = "Unable to create user's home directory"
		return ERROR.CANT_CREATE
	bootstrap_progressed.emit(0.81)
	
	var chown_task := Command.new("chown", ["1000:1000", MOUNT_PATH + "/home/" + USER])
	if await chown_task.execute() != OK:
		last_error = "Unable to set permissions on user's home directory"
		return ERROR.CANT_CREATE
	bootstrap_progressed.emit(0.82)
	
	if DirAccess.make_dir_recursive_absolute(MOUNT_PATH + "/boot") != OK:
		last_error = "Unable to create boot directory"
		return ERROR.CANT_CREATE
	bootstrap_progressed.emit(0.83)

	if DirAccess.make_dir_recursive_absolute(MOUNT_PATH + "/etc") != OK:
		last_error = "Unable to create etc directory"
		return ERROR.CANT_CREATE
	bootstrap_progressed.emit(0.84)

	if DirAccess.make_dir_recursive_absolute(MOUNT_PATH + "/.etc") != OK:
		last_error = "Unable to create .etc directory"
		return ERROR.CANT_CREATE
	bootstrap_progressed.emit(0.85)

	# setup boot partition & install bootloader
	var mkvfat_task := Command.new("mkfs.vfat", [part1])
	if await mkvfat_task.execute() != OK:
		last_error = "Unable to create partition for bootloader"
		return ERROR.PARTITIONING_FAILED
	bootstrap_progressed.emit(0.88)
	
	var dosfs_task := Command.new("dosfslabel", [part1, "frzr_efi"])
	if await dosfs_task.execute() != OK:
		last_error = "Unable to create partition label for bootloader"
		return ERROR.PARTITIONING_FAILED
	bootstrap_progressed.emit(0.90)

	var mntvfat_task := Command.new("mount", ["-t", "vfat", part1, MOUNT_PATH + "/boot/"])
	if await mntvfat_task.execute() != OK:
		last_error = "Unable to mount boot partition"
		return ERROR.PARTITIONING_FAILED
	bootstrap_progressed.emit(0.94)
	
	var bootctl_task := Command.new("bootctl", ["--esp-path=" + MOUNT_PATH + "/boot/", "install"])
	if await bootctl_task.execute() != OK:
		last_error = "Unable to install boot loader"
		return ERROR.PARTITIONING_FAILED
	bootstrap_progressed.emit(0.96)
	
	var boot_parted_task := Command.new("parted", [to_disk.path, "set", "1", "boot", "on"])
	if await boot_parted_task.execute() != OK:
		last_error = "Unable to configure boot loader"
		return ERROR.PARTITIONING_FAILED
	bootstrap_progressed.emit(1.0)
	
	return ERROR.OK


# TODO: Implement this
#SYS_CONN_DIR="/etc/NetworkManager/system-connections"
#if [ -d ${SYS_CONN_DIR} ] && [ -n "$(ls -A ${SYS_CONN_DIR})" ]; then
#    mkdir -p -m=700 ${MOUNT_PATH}${SYS_CONN_DIR}
#    cp  ${SYS_CONN_DIR}/* \
#        ${MOUNT_PATH}${SYS_CONN_DIR}/.
#fi
## Copy over all network configuration from the live session to the system
func copy_network_config() -> Error:
	return OK


## Simple container for holding information about a disk
class Disk:
	var name: String
	var path: String
	var model: String
	var size: String
	var install_found: bool
