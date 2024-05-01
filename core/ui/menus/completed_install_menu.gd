extends Control

@onready var yes_button := $%YesButton
@onready var no_button := $%NoButton
# Called when the node enters the scene tree for the first time.
func _ready():
	yes_button.pressed.connect(_on_yes_pressed)
	no_button.pressed.connect(_on_no_pressed)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass
	
func _on_yes_pressed() -> void:
	var reboot := Command.new("reboot")
	if await reboot.execute() != OK:
		return
func _on_no_pressed() -> void:
	pass
