local mods = minetest.get_mod_storage()
local modname = minetest.get_current_modname()

mapgen.structures = minetest.deserialize(mods:get_string("structures") ~= "" or "{}") or {}

function mapgen.register_structure(name, def)
	mapgen.structures[name] = {}

	mapgen.registered_structures[name] = def

	minetest.register_node(modname..":"..name, {
		drawtype = "airlike",
		walkable = false,
		pointable = false,
		buildable_to = true,
		paramtype = "light",
		sunlight_propagates = true,
		groups = {structure_placeholder = 1},
	})

	minetest.register_decoration({
		deco_type = "simple",
		place_on = def.placeon or "vk_nodes:grass",
		decoration = modname..":"..name,
		fill_ratio = def.rarity,
		biomes = {"green_biome"},
		y_min = def.y_min or 8,
		y_max = def.y_max or 8,
		flags = "force_placement, all_floors",
	})
end

minetest.register_lbm({
	label = "Place structures",
	name = modname..":place_structure",
	nodenames = {"group:structure_placeholder"},
	run_at_every_load = true,
	action = function(pos, node)
		local schemname = mapgen.get_schemname(node.name)
		local result
		local structure = mapgen.registered_structures[schemname]

		minetest.remove_node(pos)

		if mapgen.structure_is_nearby(pos, mapgen.registered_structures[schemname].bubble) == false then
			vkore.scan_flood(pos, structure.radius, function(p, dist)
				local nodename = minetest.get_node(p).name

				if p.y < pos.y-1 or p.y > pos.y+1 then return false end -- Just scan a node off from y 8 (ground level)

				if p.y <= 8 then
					if nodename == "air" then
						result = "Will jut over edge"
						return true
					end
				else
					if nodename == "vk_nodes:grass" then -- There is terrain in the way
						result = "Will break terrain"
						return true
					end
				end
			end)

			pos.y = pos.y - 1

			if math.abs(pos.x) + structure.radius >= vkore.settings.world_size or
			math.abs(pos.z) + structure.radius >= vkore.settings.world_size then
				result = "Too close to map edge"
			end

			if not result then
				result = minetest.place_schematic(
					pos, -- pos to place schematic
					minetest.get_modpath(modname) .. "/schems/structures/" .. schemname .. ".mts",
					"random", -- rotation
					nil, -- replacements
					true, -- force_placement
					"place_center_x, place_center_z" -- flags
				)
			end
		else
			result = "Pops a bubble"
		end

		if result == true then
			mapgen.new_structure(schemname, pos)
			minetest.log("action", "Spawned structure " .. schemname .. " at "..minetest.pos_to_string(pos))
			mapgen.populate_structure(schemname, pos, structure.radius)
		elseif vkore.settings.game_mode == "dev" then
			minetest.log("error",
				"Failed to spawn structure " .. schemname .. " at " .. minetest.pos_to_string(pos) ..
				". result = " .. dump(result)
			)
		end
	end
})

function mapgen.get_schemname(name)
	return name:sub(name:find(":")+1)
end

-- Check to see if a structure placed at pos will break another structure's 'bubble' with its own
function mapgen.structure_is_nearby(pos, bubble)
	for structure, positions in pairs(mapgen.structures) do
		local bubble2 = mapgen.registered_structures[structure].bubble

		for _, structpos in ipairs(positions) do
			if vector.distance(pos, structpos) <= bubble + bubble2 then
				return true
			end
		end
	end

	return false
end

function mapgen.new_structure(schemname, pos)
	table.insert(mapgen.structures[schemname], pos)
	mods:set_string("structures", minetest.serialize(mapgen.structures))
end

function mapgen.populate_structure(schemname, structurepos, radius)
	minetest.log("info", "Running populate_structure.")
	local poslist = minetest.find_nodes_in_area_under_air(
		vector.add(structurepos, radius),
		vector.subtract(structurepos, radius),
		"vk_npcs:tavern_keeper"
	)
	for i = 1, #poslist do
		local pos = poslist[i]
		local node = minetest.get_node(pos)
		if (node.name == "vk_npcs:tavern_keeper") then
			minetest.log("info", "Found a tavern keeper at: "..dump(pos))
			-- Need to remove her and add a marker
			minetest.remove_node(pos)
			minetest.remove_node( {x = pos.x, y = (pos.y + 1), z = pos.z} )
			minetest.set_node( {x = pos.x, y = pos.y + 4, z = pos.z}, { name = "vk_npcs:tavern_marker" })
			-- Add her back as an npcmob that can walk around
			minetest.add_entity({x = pos.x, y = (pos.y + 1), z = pos.z}, "vk_npcs:tavern_keeper")
			-- !!! TEST TEST TEST TODO DELETE THIS !!!
			minetest.add_entity({x = pos.x, y = (pos.y + 1), z = pos.z - 42}, "vk_mapgen:cantilever")
			return 1
		end
	end
end

mapgen.register_structure("town1", {
	rarity = 0.00005,
	radius = 40,
	bubble = 100,
})

-- mapgen.register_structure("dungeon1", {
-- 	rarity = 0.00001,
-- 	radius = 7,
-- 	bubble = 25,
-- })

local function count_nodes_above(pos, maxsteps)
	local direction = {x = 0, y = 1, z = 0}
	local count = 0
	local topnode = 0
	local node
	
	for i = 0, maxsteps - 1 do
		node = minetest.get_node(pos)
		minetest.log("info", "count_nodes_above() found node: "..node.name)
		if (node.name == "air") then
			if (i > 1) then 
				return count, topnode
			end
		else
			count = count + 1
		end
		topnode = topnode + 1
		pos = vector.add(pos, direction)
	end
	return count, topnode
end

local function move_nodes_and_entities_above(pos, deflection, numnodes)
	local topnodepos = {x = pos.x, y = pos.y + numnodes - 1, z = pos.z}

	local startnode
	local endnode
	local startpos
	local direction
	local step
	if (deflection.y > 0) then
		-- if moving up we need to move the top node up first and work downwards
		startnode = numnodes - 1
		endnode = 0
		startpos = topnodepos
		direction = {x = 0, y = -1, z = 0}
		step = -1
	elseif (deflection.y < 0) then
		-- if moving down we need to move the bottom node down first and work upwards
		-- TODO consider what may be underneath the bottom node. It may not be air. If we are looking too low, it will move the wrong stuff.
		startnode = 0 
		endnode = numnodes - 1
		startpos = pos
		direction = {x = 0, y = 1, z = 0}
		step = 1
	else
		return false
	end

	local posi = startpos
	for i = startnode, endnode, step do
		local node = minetest.get_node(posi)
		if node then
			minetest.log("info", "move_nodes_and_entities_above() found node: "..node.name)
			-- TODO can we transfer any metadata?
			local newpos = { x = posi.x, y = posi.y + deflection.y, z = posi.z }

			minetest.remove_node (posi)

			minetest.add_node (newpos, node)  --<<<<<<<<<<<<<<<<<<<<<<<<< TODO see if a player or entity is right on top and teleport them too, at same / correct height
		end
		posi = vector.add(posi, direction)
	end

	return true
end

-- TODO this needs to go in a separate puzzles mod or contraptions mod or just in the vk nodes one.
minetest.register_entity("vk_mapgen:cantilever", {   
	physical = true,
	collide_with_objects = false,
	visual = "cube",
	visual_size = {x = 5.75, y = 1, z = 1},
	collisionbox = {-2, -3, -0.5, 2, 0, 0.5}, --was collisionbox = {-2.5, -3, -0.5, 2.5, 3, 0.5}, but we had issues accessing nodes above it
	mesh = "",
	textures = {"nodes_wood.png", "nodes_wood.png", "nodes_wood.png", "nodes_wood.png", "nodes_wood.png", "nodes_wood.png"},
	timeout = 0,
	glow = 0,
	stepheight = 0.6,
	buoyancy = 0,
--	lung_capacity = 0, -- seconds
	hp = 99,
--	max_hp = 0,
	initleft = {x = -2, y = 0, z = 0},
	initright = {x = 2, y = 0, z = 0},
	left = vector.new(-2, 0, 0),
	right = vector.new(2, 0, 0),
	minleft = {x = -2, y = -3, z = 0},
	minright = {x = 2, y = -3, z = 0},
	message = "",
--	on_step = mobkit.stepfunc, 
	on_activate = function(self, staticdata, dtime_s)
	end,
--	get_staticdata =
--	animation =
   on_construct = function (pos)
      --minetest.get_node_timer (pos):start (1.0)
   end,

   on_destruct = function (pos)
     -- minetest.get_node_timer (pos):stop ()
   end,

   on_step = function (self, elapsed)
     local obj = self.object
     local pos = obj:get_pos()
     if (pos == nil) then
		return true
	 end
      --local thepos = self.object:get_pos()
      --local pos = vector.new(thepos.x, thepos.y, thepos.z)
      local leftpos = vector.add(pos, self.left)--{ x = pos.x - 2, y = pos.y + 1, z = pos.z }    --<<< TODO must keep these in the metadata and update based on existing deflection
      local rightpos = vector.add(pos, self.right)--{ x = pos.x + 2, y = pos.y + 1, z = pos.z }   --    Also theoretically the x would change as the y does.
      -- Do all our manipulations one block above the cantilever so they sit on top of it rather than inside it.
      -- BUG! Actually when one side is at the highest point that makes them look one block too high in the air, and at the lowest point like one block too low, so need to correct for that too
      leftpos = vector.add(leftpos, { x = 0, y = 1, z = 0 })
      rightpos = vector.add(rightpos, { x = 0, y = 1, z = 0 })
      --local nodeleft = minetest.get_node_or_nil (leftpos)
      --local noderight = minetest.get_node_or_nil (rightpos)
      local aboveleftpos = { x = leftpos.x, y = leftpos.y, z = leftpos.z }--local aboveleftpos = { x = leftpos.x, y = leftpos.y + 1, z = leftpos.z }
      local aboverightpos = { x = rightpos.x, y = rightpos.y, z = rightpos.z }--local aboverightpos = { x = rightpos.x, y = rightpos.y + 1, z = rightpos.z }
      local aboveleft, topnodeleft = count_nodes_above(aboveleftpos, 256)
      local aboveright, topnoderight = count_nodes_above(aboverightpos, 256)
      if ((aboveleft > aboveright and self.left.y > self.minleft.y) or (aboveright == aboveleft and self.left.y > self.right.y)) then
		-- Move left side down and right side up
		-- BUG sometimes when a new block is added above the higher side, that block falls below the level where blocks are counted and will not be lifted back up
		-- basically, add one node above on the left, LHS swings all the way to the bottom, still counts left: 1 right 0, add 1 above right, now left is 0 as it comes up.
		-- The difference between the left and right coordinates should always be zero or >= 2 but if it was 1, it would be wrong to move both stacks of blocks here!
		move_nodes_and_entities_above(leftpos, { x = 0, y = -1, z = 0 }, topnodeleft)
		move_nodes_and_entities_above(rightpos, { x = 0, y = 1, z = 0 }, topnoderight)
		if (aboveright == aboveleft and self.left.y - self.right.y < 2) then
			self.right.y = initleft.y
			self.left.y = self.right.y
		else
			self.left.y = self.left.y - 1
			self.right.y = self.right.y + 1
		end
		leftpos = vector.add(pos, self.left)
		rightpos = vector.add(pos, self.right)
      elseif ((aboveright > aboveleft and self.right.y > self.minright.y) or (aboveright == aboveleft and self.right.y > self.left.y)) then
		-- Move right side down and left side up
		move_nodes_and_entities_above(leftpos, { x = 0, y = 1, 0 }, topnodeleft)
		move_nodes_and_entities_above(rightpos, { x = 0, y = -1, 0 }, topnoderight)
		if (aboveright == aboveleft and self.right.y - self.left.y < 2) then
			self.right.y = initleft.y
			self.left.y = self.right.y
		else
			self.right.y = self.right.y - 1
			self.left.y = self.left.y + 1
		end
		leftpos = vector.add(pos, self.left)
		rightpos = vector.add(pos, self.right)
      end

      -- Calculate entity rotation TODO if we draw a fulcrum, that does not rotate, and really we want to shear, not rotate
      local origangle = math.asin(self.left.y / 3)
      local angle = origangle
      if (angle > math.pi / 4.0) then
		angle = math.pi / 4.0
	  elseif (angle < -math.pi / 4.0) then
		angle = -math.pi / 4.0
	  end
	  local newmessage = "Above left: " .. aboveleft .. " right: " .. aboveright .. " angle: " .. origangle .. "."
	  --if (not newmessage == self.message) then
		minetest.chat_send_all(newmessage)
		self.message = newmessage
	  --end
	  --angle = angle + math.pi
      obj:set_rotation({x = 0, y = 0, z = angle})
      

      -- do run again
      return true
   end
})
