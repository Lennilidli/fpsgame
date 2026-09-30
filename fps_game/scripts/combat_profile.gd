class_name CombatProfile
extends Resource
## Every value that shapes how melee feels. Shared by the player and enemies so both
## play by the same rules. Edit it in the Inspector, or live in-game with F1.

@export_group("Global")
## Scales every combat timing. Below 1 = slower, heavier fights.
@export_range(0.25, 2.0, 0.05) var combat_speed := 1.0

@export_group("Windup")
## Time to draw the weapon fully back.
@export_range(0.1, 1.5, 0.01) var windup_time := 0.5
## Earliest a swing can be released after starting the windup.
@export_range(0.05, 1.5, 0.01) var min_windup := 0.35
## Holding this long gives full damage.
@export_range(0.2, 3.0, 0.05) var full_charge_time := 1.1
## Damage multiplier of a minimum-charge swing.
@export_range(0.0, 1.0, 0.01) var charge_min_damage := 0.7
## How far back the weapon is drawn. 1 = default pose, higher = bigger backswing.
@export_range(0.3, 2.0, 0.05) var backswing_amount := 1.0
## Windup easing. Higher = snaps back quickly, then settles slowly.
@export_range(1.0, 4.0, 0.1) var windup_ease := 2.0

@export_group("Swing")
## Brief extra pull-back right before the strike (the "cock" of the swing).
@export_range(0.0, 0.3, 0.01) var anticipation_time := 0.08
@export_range(0.0, 0.6, 0.01) var anticipation_amount := 0.15
## Swing easing. Higher = slow start and a fast, heavy finish.
@export_range(1.0, 4.0, 0.1) var swing_ease := 2.0
## On a miss, the weapon keeps travelling past the end pose.
@export_range(0.0, 0.8, 0.01) var follow_through_time := 0.3
@export_range(0.0, 1.0, 0.05) var follow_through_amount := 0.35
## Time to return to guard after a swing. You can't act during it.
@export_range(0.05, 1.5, 0.01) var recover_time := 0.4

@export_group("Impact")
## Freeze frames when a swing hits flesh. Scaled by the attack's damage and charge, so a
## full overhead freezes longer than a quick side slash.
@export_range(0.0, 0.3, 0.005) var hit_stop := 0.09
## After a hit the blade keeps cutting this fraction of its remaining swing before it
## stops (the "bite"), so hits sink in instead of tapping.
@export_range(0.0, 0.6, 0.01) var hit_bite := 0.15
@export_range(0.01, 0.2, 0.01) var hit_bite_time := 0.05
## How far the weapon rebounds toward the backswing after a hit.
@export_range(0.0, 1.0, 0.05) var hit_bounce_amount := 0.25
@export_range(0.05, 1.0, 0.01) var hit_bounce_time := 0.25
## If on, the swing cuts through the target instead of bouncing off.
@export var hit_passes_through := false
## Freeze frames when a swing is blocked.
@export_range(0.0, 0.3, 0.005) var block_stop := 0.1
@export_range(0.0, 1.0, 0.05) var block_bounce_amount := 0.5
## How fast a blocked blade is knocked back. Short = crisp deflection.
@export_range(0.05, 1.0, 0.01) var block_bounce_time := 0.15
## Stun after being blocked: the deflected blade holds still this long before returning.
@export_range(0.0, 1.5, 0.05) var blocked_recoil := 0.25
## Swings bounce off walls and props.
@export var world_collision := true
@export_range(0.0, 1.0, 0.05) var world_bounce_amount := 0.5

@export_group("Defense")
## A block raised this recently when hit counts as a parry.
@export_range(0.0, 0.6, 0.01) var parry_window := 0.2
@export_range(0.0, 2.5, 0.05) var parry_stagger := 1.0
## Stagger from taking a hit. It interrupts windups and blocks.
@export_range(0.0, 1.0, 0.01) var flinch_time := 0.35
@export_range(0.0, 2.5, 0.05) var guard_break_stagger := 1.0
## Time to move the weapon into a block pose (visual only; blocks work immediately).
@export_range(0.03, 0.5, 0.01) var block_raise_time := 0.15
## Stamina lost per point of blocked damage.
@export_range(0.0, 2.0, 0.05) var block_cost_ratio := 0.8

@export_group("Input buffer")
## How long a tapped attack waits for the current action to finish (s). The default
## covers a whole swing + recovery; lower it for a stricter timing window. Held buttons
## stay queued until released. 0 = no buffering.
@export_range(0.0, 3.0, 0.05) var input_buffer_time := 1.5
## Queued swings take your latest mouse direction instead of the one you pressed with.
@export var buffer_follows_mouse := false

@export_group("Stamina")
@export_range(0.0, 80.0, 1.0) var stamina_regen := 25.0
@export_range(0.0, 3.0, 0.05) var regen_delay := 0.8
@export_range(0.0, 40.0, 1.0) var feint_cost := 8.0

@export_group("Movement & turning")
@export_range(0.0, 1.0, 0.05) var windup_move := 0.6
@export_range(0.0, 1.0, 0.05) var swing_move := 0.35
@export_range(0.0, 1.0, 0.05) var block_move := 0.55
## Max turn speed while winding up (deg/s). 0 = no limit.
@export_range(0.0, 720.0, 10.0) var windup_turn_cap := 360.0
## Max turn speed while swinging (deg/s). 0 = no limit. Stops 180° mouse flicks.
@export_range(0.0, 720.0, 10.0) var swing_turn_cap := 150.0

@export_group("Camera (player)")
## Camera roll/pitch that follows your swing (degrees).
@export_range(0.0, 10.0, 0.1) var swing_camera_roll := 2.5
@export_range(0.0, 0.3, 0.005) var hit_camera_shake := 0.05
## Camera jolt in the swing's direction when your hit lands (degrees).
@export_range(0.0, 8.0, 0.1) var hit_camera_kick := 2.0
@export_range(0.0, 0.3, 0.005) var block_camera_shake := 0.03

@export_group("Hitboxes")
## Thickness of the blade hitbox (m). Hits land when the blade comes this close to a body.
@export_range(0.01, 0.3, 0.01) var blade_radius := 0.08
## Only the outer blade deals hits: from this fraction of its length to the tip. The part
## near the hilt passes over targets, so overheads come down onto the head instead of
## clipping it early. Guards still catch the whole blade.
@export_range(0.0, 0.9, 0.05) var edge_start := 0.45
## Extra forgiveness for blade-on-blade contact (m). Higher = blocks catch more reliably but
## the blade stops visibly short of the guard.
@export_range(0.0, 0.6, 0.01) var block_contact_bonus := 0.1
## A correct guard also catches a blade that only brushes past within this distance (m),
## at its closest point. Too low and some blows slip past the guard to the body.
@export_range(0.1, 1.0, 0.05) var guard_catch_distance := 0.35
## If on, any blade-on-blade contact blocks, even when the block direction is wrong.
## Off = MO2 style: only a correct-direction guard stops the blade.
@export var physical_blocks := false

@export_group("Overhead")
@export_range(0.1, 1.5, 0.01) var overhead_duration := 0.55
## Point in the swing motion (0-1) where the blade faces forward. Hits come from
## hitbox contact; this only times AI reactions and the camera lean.
@export_range(0.1, 1.0, 0.01) var overhead_impact := 0.8
@export_range(0.1, 3.0, 0.05) var overhead_damage := 1.25
@export_range(0.0, 50.0, 1.0) var overhead_stamina := 18.0

@export_group("Thrust")
@export_range(0.1, 1.5, 0.01) var thrust_duration := 0.42
@export_range(0.1, 1.0, 0.01) var thrust_impact := 0.65
@export_range(0.1, 3.0, 0.05) var thrust_damage := 0.85
@export_range(0.0, 50.0, 1.0) var thrust_stamina := 12.0

@export_group("Side swings")
@export_range(0.1, 1.5, 0.01) var side_duration := 0.5
@export_range(0.1, 1.0, 0.01) var side_impact := 0.6
@export_range(0.1, 3.0, 0.05) var side_damage := 1.0
@export_range(0.0, 50.0, 1.0) var side_stamina := 15.0
## Side swings can hit several enemies in one sweep (with Hit Passes Through).
@export var side_cleave := true


## Stats for one attack direction (0 overhead, 1 thrust, 2/3 sides; matches MeleeCombat.Dir).
func attack(dir: int) -> Dictionary:
	match dir:
		0:
			return {"duration": overhead_duration, "impact": overhead_impact, "damage": overhead_damage, "stamina": overhead_stamina, "cleave": false}
		1:
			return {"duration": thrust_duration, "impact": thrust_impact, "damage": thrust_damage, "stamina": thrust_stamina, "cleave": false}
	return {"duration": side_duration, "impact": side_impact, "damage": side_damage, "stamina": side_stamina, "cleave": side_cleave}
