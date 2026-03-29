local modname = minetest.get_current_modname()

local default_hit_replies = {
	"Keep your weapons to yourself.",
	"Stop that.",
	"Do I need to call a guard?",
	"Are you done or are you going to wear yourself out doing that?",
	"Didn't your parents tell you not to attack strangers?",
	"I can hit back too you know.",
	"Enough!",
	"Go practice that somewhere else.",
}

local PLAYER = 0
local NPC = 1

local function prettify(npcname)
		local output = npcname:gsub("_", " ")

		return output:gsub("^(.)", string.upper)
end

--[[
	context is used to save formspec info when a player is interacting with npcs.
	It is cleared on exit/server restart
	Default values:
	{
		tab = 1, -- Current tab the player is on
		npcdef = def, -- NPC definition. Used to grab convos and NPC names
		quest = 1, -- Selected quest in quest list
		quests = {}, -- List of quests availiable from npc
	}
]]
local context = {}
minetest.register_on_leaveplayer(function(player) context[player:get_player_name()] = nil end)

local function register_npc(name, def)
	def.npcname = name

	minetest.register_node(modname..":"..name, {
		npcname = name,
		description = "NPC "..prettify(name),
		drawtype = "mesh",
		mesh = "player.obj",
		visual_scale = 0.093,
		wield_scale = vector.new(0.093, 0.093, 0.093),
		tiles = {def.texture},
		paramtype = "light",
		paramtype2 = "facedir",
		selection_box = {
			type = "fixed",
			fixed = {
				{-0.45, -0.5, -0.25, 0.45, 1.45, 0.25},
			}
		},
		collision_box = {
			type = "fixed",
			fixed = {
				{-0.45, -0.5, -0.25, 0.45, 1.45, 0.25},
			}
		},
		groups = {unbreakable = 1, loadme = 1, overrides_pointable = 1},
		on_construct = function(pos)

		end,
		on_punch = function(pos, node, puncher, ...)
			if def.on_punch and def.on_punch(pos, node, puncher, ...) then
				return
			end

			if def.hit_replies and puncher and puncher:is_player() then
				minetest.chat_send_player(puncher:get_player_name(), ("<%s> "):format(prettify(name))..def.hit_replies[math.random(1, #def.hit_replies)])
			end
		end,
		on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
			if not clicker or not clicker:is_player() then return end

			local pname = clicker:get_player_name()

			if not context[pname] or context[pname].npcdef.npcname ~= name then
				context[pname] = {
					tab = 1,
					npcdef = def,
					quest = 1
				}
			end

			vk_quests.show_npc_form(pname, context[pname])
		end
	})
end

local function evaluate_condition(pname, pcontext, cond)
	if cond == nil then return true end
	local self = pcontext.npcself
	local thevalue = nil
	local lastvalname = nil
	local lastvalue = nil
	for i, valname in pairs(cond.values) do
		if valname == "following" then
			-- following will give the name of the character they are following which must be checked against
			thevalue = mobkit.recall(self, "following") == pname
		elseif valname == "attacking" then
			thevalue = mobkit.recall(self, "attacking") ~= nil
		elseif valname == "player.gold" then
			local player = core.get_player_by_name(pname)
			if player == nil then
				thevalue = 0
			else
				thevalue = player:get_meta():get_int("gold")
			end
		elseif valname == nil then
			thevalue = nil
		else
			-- A valid number or nil
			thevalue = tonumber(valname)
		end
		
		if cond.operation == "if" or cond.operation == "and" then
			if not thevalue then return false end
		elseif cond.operation == "not" then
			if thevalue then return false end
		elseif cond.operation == "or" then
			if thevalue then return true end
		elseif cond.operation == "greaterthan" then
			minetest.log("info", ("npc talk greaterthan condition, lastvalname: %s lastvalue: %s valname %s thevalue: %s"):format(lastvalname, lastvalue, valname, thevalue))
			if lastvalue ~= nil then
				if thevalue ~= nil and not (lastvalue > thevalue) then return false end
			end
		elseif cond.operation == "lessthan" then
			minetest.log("info", ("npc talk lessthan condition, lastvalname: %s lastvalue: %s valname %s thevalue: %s"):format(lastvalname, lastvalue, valname, thevalue))
			if thevalue == nil then return false end
			if lastvalue ~= nil then
				if not (lastvalue < thevalue) then return false end
			end
		elseif cond.operation == "equals" then
			if lastvalue == nil then return false end
			if lastvalue ~= nil then
				if not (lastvalue == thevalue) then return false end
			end
		end
		
		lastvalname = valname
		lastvalue = thevalue
	end
	-- TODO here is where we would check any subconditions, not yet implemented
	return true
end

local function select_talk_lines(pname, pcontext, convo_content, playertalk, npctalk)
	local lines = 0
	-- Nested talk can be a list or a single talk object
	if convo_content == nil then return 0 end
	if convo_content.who ~= nil then
		-- So make sure we are dealing with a list
		convo_content = {convo_content}
	end
	for _, talk in pairs(convo_content) do
		if type(talk) ~= 'table' then
			-- This condition happened once when telling the follower to stop following me, but cannot yet reproduce so log it and skip:
			minetest.log("info", ("Error unexpected talk data: '%s' in convo content: '%s'. type(talk): '%s'."):format(dump(talk or "?"), dump(convo_content or "?"), (type(talk) or "?")))
		else
			local canshowtext = true
			local line = nil
			local cond = talk.condition
			if evaluate_condition(pname, pcontext, cond) then
				if talk.who == PLAYER then
					lines = lines + 1
					table.insert(playertalk, talk)
				elseif talk.who == NPC then
					lines = lines + 1
					table.insert(npctalk, talk)
				end
			end
			--if line then markup = markup .. "\"" .. minetest.formspec_escape(line) ..  "\"\n" end
			--if line then markup = markup .. ("<action name=\"%d\">"):format(lines) .. minetest.formspec_escape(line) ..  "</action>\n" end
		end
	end
	return lines
end

function vk_quests.show_npc_form(pname, pcontext)
	local temp
	local npcname = pcontext.npcdef.npcname
	local npcself = pcontext.npcself
--	local formspec = ([[
--		size[8,6]
--		real_coordinates[true]
--		label[0.2,0.3;%s]
--	]]):format(
--		prettify(npcname)
--	)
	local formspec = ([[
		size[12,6]
		real_coordinates[true]
		label[0.2,0.3;%s]
	]]):format(
		prettify(npcname)
	)


	if not pcontext.npcdef.convos then
		minetest.chat_send_player(pname, ("<%s> "):format(prettify(npcname)).."I have nothing to say.")
		return
	end

	local convos = ""
	local convo_cname = ""
	local convo_content
	temp = 0 -- tab number
	for cname, content in pairs(pcontext.npcdef.convos) do
		temp = temp + 1

		-- Save the content of the currently selected convo for later use
		if temp == pcontext.tab then
			convo_content = content
			convo_cname = cname
		end

		convos = convos .. cname .. ","
	end

	convos = convos:sub(1, -2) -- Remove trailing comma

	formspec = formspec ..
		"tabheader[0,2;1;convos;"..convos..";".. pcontext.tab ..";false;true]"

	local quests = {}
	local quest_convo = false

	for _, quest in pairs(convo_content) do
		if vk_quest[quest] then
			quest_convo = true
			table.insert(quests, vk_quest[quest])
		end
	end

	if quest_convo then
		local comments = quests[pcontext.quest].comments

		-- Remove quests in progress
		for k, quest in ipairs(quests) do
			if vk_quests.get_unfinished_quest(pname, quest.qid) then
				table.remove(quests, k)
			end
		end

		if #quests > 0 then
			formspec = formspec ..
				"hypertext[0,2.2;8,4;comment;\""..comments[math.random(1, #comments)].."\"]" ..
				"textlist[0,3.5;8,2.5;quests;"

			pcontext.quests = {}
			for _, quest in ipairs(quests) do
				table.insert(pcontext.quests, quest.qid)
				formspec = ("%s%s - %s,"):format(
					formspec,
					quest.description,
					minetest.formspec_escape(quest.rewards_description)
				)
			end

			formspec = formspec:sub(1, -2) -- Remove trailing comma
			formspec = formspec .. ";"..pcontext.quest..";false]"
		else
			formspec = formspec .. "label[0,2.4;\"I don't have any quests for you.\"]"
		end
	elseif pcontext.npcdef.convos.Talk or pcontext.npcdef.convos.Rumors then --and convo_cname == "Talk" then
		local markup =  "hypertext[0,2.2;12,4;talk;"
		local firsttalk = nil
		local firsttalkindex = 0
		local firsttalkrand = 0
		local playertalk = {}
		local npctalk = {}
		local lines = 0
		local playerfirst = false -- true if the player says first line of the conversation else the npc does.
		
		--See if we are continuing an existing conversation
		if pcontext.nexttalk ~= nil then
			convo_content = pcontext.nexttalk -- TODO if it is empty they should say "I have nothing to say" maybe.
			pcontext.nexttalk = nil
		end
		-- We probably should build a list of all the talk objects that pass their conditions,
		-- Then offer a choice between them if they are player speech or choose at random if npc speech.
		-- If we are already deep into a conversation, we need to recall where and resume it
		-- Like globals lasttalkobj and lasttalkindex.... index is the random index to choose which version of the text was shown
		-- So, say the npc says something and the player chooses a reply, then the form should reopen with players chosen reply at the top
		-- and any further response from the NPC underneath. For longer conversations any further player responses would be underneath.
		-- Or actually better not to repost the previous line of dialogue and only show the new one.
		lines = select_talk_lines(pname, pcontext, convo_content, playertalk, npctalk)

		-- If both the player and the NPC have lines that could start a conversation, we currently choose who starts at random
		-- although this approach has drawbacks if it could cause the player to miss quest dialog, so careful consideration needs
		-- to be given to how the conversations are designed and the conditions attached to them.
		-- The ideal conversation system would stop the NPC repeating old conversations at least for a certain period of time.
		if #npctalk > 0 and (#playertalk < 1 or math.random(1, 2) == 1) then
			playerfirst = false
			firsttalkindex = math.random(1, #npctalk)
			firsttalkrand = math.random(1, #(npctalk[firsttalkindex].line))
			local line = npctalk[firsttalkindex].line[firsttalkrand]
			markup = "hypertext[0,2.2;12,4;comment;" .. minetest.formspec_escape(line) .. "]\n"
			minetest.log("info", ("npc talk markup: '%s'"):format(markup))

			-- This is where we also need to do any associated npc actions.
			local player = core.get_player_by_name(pname)
			if player ~= nil then
				local cost = npctalk[firsttalkindex].cost
				cost = tonumber(cost)
				if cost ~= nil then
					-- cost will be subtracted from the player's gold.
					-- Negative values ought to work here too for an npc to pay the player.
					local pgold = player:get_meta():get_int("gold")
					pgold = pgold - cost
					if pgold < 0 then pgold = 0 end
					--player:get_meta():set_int("gold", pgold)--  We will use players.set_gold(player, newgold) instead as it handles HUD
					players.set_gold(player, pgold)
					-- !!!! TODO add it to npc gold
				end
				
				local action = npctalk[firsttalkindex].action
				local npcself = pcontext.npcself
				if npcself ~= nil then
					if action == "follow" then
						minetest.log("action", ("npcself '%s' will start following player '%s'"):format(npcself.name or "?", pname or "?"))
						mobkit.remember(npcself, "following", pname)
					elseif action == "nofollow" then
						mobkit.remember(npcself, "following", nil)
					elseif action == "attack" then
						-- TODO need code for attacking nearby enemy only
						mobkit.remember(npcself, "standddown", nil)
						mobkit.remember(npcself, "attack", true)
					elseif action == "noattack" then
						-- TODO standing down needs a timeout and/or waiting for moving certain distance / player to attack again
						mobkit.remember(npcself, "attack", false)
						mobkit.remember(npcself, "standddown", 300)
					end
				end
				
			end
			
			-- Read player responses from child talk object
			local nexttalk = npctalk[firsttalkindex].talk
			if nexttalk and #nexttalk > 0 then
				playertalk = {}
				local unused = {}
				if select_talk_lines(pname, pcontext, nexttalk, playertalk, unused) > 0 then
					markup = markup .. "textlist[0,3.5;12,2.5;talk;"
					for pindex, ptalk in pairs(playertalk) do
						line = ptalk.line[math.random(1, #(ptalk.line))]
						markup = markup .. minetest.formspec_escape(line) .. ","
					end
					markup = markup:sub(1, -2) -- Remove trailing comma
					markup = markup .. "]"
				end
				
			end
			
		elseif #playertalk > 0 then
			markup = "textlist[0,3.5;12,2.5;talk;"
			for pindex, ptalk in pairs(playertalk) do
				line = ptalk.line[math.random(1, #(ptalk.line))]
				markup = markup .. minetest.formspec_escape(line) .. ","
			end
			markup = markup:sub(1, -2) -- Remove trailing comma
			markup = markup .. "]"
		end
		pcontext.playertalk = playertalk

		formspec = formspec .. markup .. "]" 
	else
		formspec = formspec .. "label[0,2.4;\"I don't have anything to say.\"]"
	end

	minetest.show_formspec(pname, "npcform", formspec)
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "npcform" or not fields then return end

	local pname = player:get_player_name()

	if not context[pname] then
		minetest.log("error", "Player submitted fields without context")
		minetest.close_formspec(pname, "npcform")

		return true
	end

	local update_form = false

	-- Update selected tab if changed
	if fields.convos then
		context[pname].tab = tonumber(fields.convos)

		update_form = true
	end

	if fields.quests then
		local event = minetest.explode_textlist_event(fields.quests)

		if (event.type == "CHG" or event.type == "DCL") and event.index ~= context[pname].quest then
			context[pname].quest = event.index
			update_form = true
		elseif event.type == "DCL" then
			vk_quests.start_quest(pname, context[pname].quests[event.index])
			update_form = true
		end
	end
	
	if fields.talk then
	  -- Handle conversation replies
	  local event = minetest.explode_textlist_event(fields.talk)
	  if event.type == "DCL" then
		local playertalk = context[pname].playertalk
		minetest.log("info", ("npc talk event type: %s event index: '%d'"):format(event.type, event.index))
		if playertalk and #playertalk >= event.index then
			minetest.log("info", ("player chose response: '%s' or words to that effect."):format(playertalk[event.index].line[1]))
			context[pname].nexttalk = playertalk[event.index].talk
			update_form = true
		end
	  end
	end

	if update_form then
		vk_quests.show_npc_form(pname, context[pname])
	end

	return true
end)

register_npc("blacksmith", {
	texture = "vk_npcs_blacksmith.png",
	hit_replies = default_hit_replies,
})

register_npc("stable_man", {
	texture = "vk_npcs_stable_man.png",
	hit_replies = default_hit_replies,
})

register_npc("guard", {
	texture = "vk_npcs_guard.png",
	hit_replies = default_hit_replies,
	convos = {
		Quests = {
			"kill_spider:spider",
		},
		Rumors = {
			{ 	who = NPC,
				line = {" I hear there might be something up with the tavern keeper's drinks."},
				talk = {
						{who = PLAYER, line = {"Really? Whatever do you mean?"}, talk = 
							{who = NPC, line = {"This guy told me she takes your money but then there are no drinks to be seen."}, talk =
								{
									{who = PLAYER, line = {"That can't be right. I bought a drink from her", "Sounds weird."}, talk =
										{who = NPC, line = {"They must be invisible drinks then! Yeah, that'll be it. Sorcery!"}}}}
								}
						},
						{who = PLAYER, line = {"Uhhhhh, bye."}, talk = {who = NPC, line = {"Farewell."}}}
					}
			}
		}
	}
})

register_npc("tavern_keeper", {
	texture = "vk_npcs_tavern_keeper.png",
	hit_replies = default_hit_replies,
})

local function is_clear_floor(pos, direction, steps, floormaterial)
	for i = 1, steps do
		local node = minetest.get_node(pos)
		minetest.log("info", "is_clear_floor() found node: "..node.name)
		while (node.name == "air") do
			pos.y = pos.y - 1
			node = minetest.get_node(pos)
			minetest.log("info", "is_clear_floor() found node: "..node.name)
		end
		if (node.name ~= floormaterial) then
			return false
		end
		if (minetest.get_node({x = pos.x, y = pos.y + 1, z = pos.z}).name ~= "air") then
			minetest.log("info", "is_clear_floor() found unclear node above ground: "..(minetest.get_node({x = pos.x, y = pos.y + 1, z = pos.z}).name))
			return false
		end
		if (minetest.get_node({x = pos.x, y = pos.y + 2, z = pos.z}).name ~= "air") then
			minetest.log("info", "is_clear_floor() found unclear node 2 blocks above ground: "..(minetest.get_node({x = pos.x, y = pos.y + 2, z = pos.z}).name))
			return false
		end
		pos = vector.add(pos, direction)
	end
	return true
end

local NPC_SPAWN_RADIUS = 100

local function tavern_keeper_spawned(tavern_keeper)
	-- Add a follower in the tavern, if one does not already exist nearby
	local followerexists = false
	local objs_in_area = minetest.get_objects_inside_radius(tavern_keeper.initial_spawn_pos, NPC_SPAWN_RADIUS+5)
	-- When the game is developed further, there should be a better way of keeping track of quest characters than this search.
	-- Then, if the follower died and a certain amount of game time, 7 days for example is passed, we can spawn another one.
	-- Also if they were last seen a long way from the player and are not involved in an active quest, consider teleporting them back to
	-- the tavern.
	-- But for now, we do a brute force search of the local area.
	for key, obj in pairs(objs_in_area) do
		if not obj:is_player() and obj:get_luaentity().name == modname..":Hrothgar_the_Mercenary" then
			--table.remove(objs_in_area, key)
			followerexists = true
			minetest.log("info", "Not spawning a new follower in the tavern as one already exists nearby.")
			break
		end
	end
	if not followerexists then
		--We need to identify which direction the town and tavern are oriented to position the follower, or look for a bit of floor space.
		--Basically the direction that has 4 uncovered floor tiles in a row in. If the tile 5 away from her is clear, and the previous 3 are clear, that is good.
		local pos
		local pos1 = vector.add(tavern_keeper.initial_spawn_pos, vector.new(0,0,5))
		local pos2 = vector.add(tavern_keeper.initial_spawn_pos, vector.new(5,0,0))
		local pos3 = vector.add(tavern_keeper.initial_spawn_pos, vector.new(0,0,-5))
		local pos4 = vector.add(tavern_keeper.initial_spawn_pos, vector.new(-5,0,0))
		if is_clear_floor(pos1, vector.new(0,0,-1), 4, "vk_nodes:wood") then
			pos = pos1
			pos.z = pos.z - 1
		elseif is_clear_floor(pos2, vector.new(-1,0,0), 4, "vk_nodes:wood") then
			pos = pos2
			pos.x = pos.x - 1
		elseif is_clear_floor(pos3, vector.new(0,0,1), 4, "vk_nodes:wood") then
			pos = pos3
			pos.z = pos.z + 1
		elseif is_clear_floor(pos4, vector.new(1,0,0), 4, "vk_nodes:wood") then
			pos = pos4
			pos.x = pos.x + 1
		else
			minetest.log("info", "Could not find clear floor for the follower in the tavern! Giving up in tavern_keeper_spawned().")
			return false
		end
		pos.y = pos.y + 1
		
		minetest.log("info", "follower added in tavern_keeper_spawned().")
		local staticdata = {waiting = true, npcname = "Hrothgar_the_Mercenary"}
		local obj = minetest.add_entity(pos, modname..":Hrothgar_the_Mercenary", minetest.serialize(staticdata))
	end
end

local function tavern_keeper_step(tavern_keeper)
	local tavernpos = mobkit.recall(tavern_keeper, "spawnpoint")
	minetest.log("info", "tavern_keeper_step().")
end

local ROAM = 0
local WAIT = 1
--local AMBUSH = 2
local FOLLOW = 2
local GOTO_COVER = 3
local ATTACK = 4

local function register_npcmob(name, def)
	def.npcname = name

	minetest.register_entity(modname..":"..name, {
	npcname = name,
	--displayname = name,
	description = "NPC "..prettify(name),
	physical = true,
	collide_with_objects = true,
	visual = "mesh",
	visual_size = vector.new(0.93, 0.93, 0.93),
	selection_box = {
		type = "fixed",
		fixed = {
			{-0.45, -0.5, -0.25, 0.45, 1.45, 0.25},
		}
	},
	collisionbox = {-0.45, 0, -0.25, 0.45, 2, 0.25},
	mesh = "player.b3d",
	textures = {def.texture or "vk_npcs_guard.png"},
	timeout = 0,
	glow = 1,
	stepheight = 0.6,
	buoyancy = 1,
	lung_capacity = 31, -- seconds
	hp = 45,
	max_hp = 55,
	strength = 6, -- strength needed so they can punch things; needs mobkit_custom
	hostility = -3,
	spawned = false,
	initial_spawn_pos = vector.new(0, 0, 0), -- Gets set automatically in the logic function.
	on_step = mobkit.stepfunc,
	on_activate = function(self, staticdata, dtime_s)
		self.attack_ok = true
		mobkit.actfunc(self, staticdata, dtime_s)
		local data = minetest.deserialize(staticdata)
		if (data ~= nil and data.waiting == true) then
			mobkit.remember(self, "waiting", true)
		end
--		if (data ~= nil and data.displayname ~= nil) then
--			self.displayname = data.npcname
--		end
	end,
	get_staticdata = mobkit.statfunc,
	on_deactivate = function(self)
		mobkit_custom.deactfunc(self)
	end,
	logic = function(self)
		mobkit.vitals(self)

		local obj = self.object
		local pos = obj:get_pos()
		
		if (not self.spawned) then
			self.initial_spawn_pos = pos
			self.spawned = true
			if (self.name == modname..":tavern_keeper") then
				tavern_keeper_spawned(self)
			else
				minetest.log("info", ("not tavern_keeper logic func: %s"):format(self.name))
			end
		end

		if self.hp <= 0 then
			mobkit.clear_queue_high(self)
			mobkit.hq_die(self) -- mob death here, relevant for QUEST characters....?
			return
		end

		if mobkit.timer(self, 1) then
			if (self.name == modname..":tavern_keeper") then
				tavern_keeper_step(self)
			else
				minetest.log("info", ("mobkit timed logic running for: %s"):format(self.name))
			end
			local priority = mobkit.get_queue_priority(self)
			local nearby_player = mobkit.get_nearby_player(self)
			local nearby_enemy = mobkit.get_nearby_enemy(self)
			local standdown = mobkit.recall(self, "standddown")
			local follow_player = nil
			
			if not nearby_enemy then
				-- Last enemy we hunted is remembered in mobkit custom hunt function
				local nearby_enemy_id = mobkit.recall(self, "lastenemy")
				if nearby_enemy_id then
					nearby_enemy = mobkit_custom.get_mob_by_id(nearby_enemy_id)
					-- TODO also need to check are they still alive?
					if not (nearby_enemy and nearby_enemy.object and
							vector.distance(nearby_enemy.object:get_pos(), pos) <= 10) then
						nearby_enemy = nil
					end
				end
			end

			local followpname = mobkit.recall(self, "following")
			if followpname ~= nil then
				local tohunt = false
				follow_player = core.get_player_by_name(followpname)
				
				--mobkit.remember(self, "waiting", false)
				
				-- Only start attacking an enemy when our player is nearby
				if nearby_enemy and follow_player and vector.distance(follow_player:getpos(), pos) <= 20 then
					-- Were we ordered to stand down?
					if not standdown or standdown < 1 then
						tohunt = true
						-- minetest.log("info", ("npcmob nearby enemy '%s' type: %s"):format(dump(nearby_enemy:get_meta()), type(nearby_enemy))) -- :get_meta():get_int("strength")
						
						if nearby_enemy.object then 
							minetest.log("info", ("npcmob nearby enemy at '%s' type: %s"):format(dump(nearby_enemy.object:get_pos()), type(nearby_enemy))) -- :get_meta():get_int("strength")
							minetest.log("action", ("npcmob is attacking nearby enemy '%s'"):format(nearby_enemy.object.name or "?"))
						else
							local debugpos = nearby_enemy:get_pos()
							minetest.log("info", ("npcmob nearby enemy at '%s' type: %s"):format(dump(debugpos), type(nearby_enemy)))
							-- minetest.log("action", ("npcmob is attacking nearby enemy '?'"))
							minetest.log("action", ("npcmob is attacking nearby enemy '%s'"):format(nearby_enemy.name or "?"))
						end
						mobkit.hq_hunt(self, ATTACK, nearby_enemy)
						-- mobkit custom currently identifies nearby enemies based on their queued behaviors, which may change
						-- so remember who we were trying to attack
						--	mobkit.remember(self, "lastenemy", nearby_enemy)
					end
				end
				
				if not tohunt then
					minetest.log("action", "npcmob is following player") --'%s'"):format(followpname)
					mobkit.hq_follow(self, FOLLOW, follow_player)
				end
			end
			
			if nearby_player and priority < ATTACK and mobkit.recall(self, "ambushing") ~= true and -- Not attacking/ambushing
			vector.distance(nearby_player:getpos(), pos) <= 10 then -- Not attacking nearby player
				if self.hostility > 0 then mobkit.hq_hunt(self, ATTACK, nearby_player) end
			end

			-- If not finding cover or hiding in cover
			--if priority < GOTO_COVER and minetest.get_node(pos).name ~= "spider:spider_cover" then
			--	local nearest_cover = minetest.find_node_near(pos, 20, "spider:spider_cover")

			--	if nearest_cover then
			--		if custom_hq_goto(self, GOTO_COVER, nearest_cover) then -- spider arrived at web
			--			ambush(self, AMBUSH)
			--		end
			--	else
					if not follow_player then
						if mobkit.recall(self, "waiting") == true then
							mobkit.lq_idle(self, 5)
						else
							mobkit.hq_roam(self, ROAM)
						end
					end
			--	end
			--elseif priority ~= AMBUSH and minetest.get_node(pos).name == "spider:spider_cover" then
			--	ambush(self, AMBUSH)
			--end
			
			if standdown and standdown > 0 then mobkit.remember(self, "standddown", standdown - 1) end -- BUG? why npcself? mobkit.remember(npcself, "standddown", standdown - 1) end
--[[
			
			-- TODO Only run anim code every 0.1 seconds
			--  self.timer = (self.timer or 0) + dtime
			--  if self.timer < 0.1 then return else self.timer = 0 end

			--
			--- Player Model animations
			local controls = player:get_player_control()

			if controls.right or controls.left or controls.down or controls.up then
				if controls.lmb or controls.rmb then
					self.object:set_animation(anims.walk_mine.range, anims.walk_mine.speed * (player:get_physics_override().speed or 1))
				else
					self.object:set_animation(anims.walk.range, anims.walk.speed * (player:get_physics_override().speed or 1))
				end
			elseif controls.lmb or controls.rmb then
				self.object:set_animation(anims.mine.range, anims.mine.speed * (player:get_physics_override().speed or 1))
			else
				self.object:set_animation(anims.stand.range, anims.stand.speed * (player:get_physics_override().speed or 1))
			end
			--- End of Player Model animations
			--

			--
			--- Start of wielditem code
			local wielditem = player:get_wielded_item()
			local wieldname = wielditem:get_name()

			if wieldname ~= last_wielded_item:get_name() then
				last_wielded_item = wielditem
				for _, func in ipairs(registered_on_wield) do
					if func(player, wielditem, last_wielded_item) then
						break
					end
				end
			end
			--- End of wielditem code
			--
--]]
		end
	end,
	animation = {
		["stand"] = {
			range = {x = 0, y = 0},
			speed = 0,
			loop = false,
		},
		["walk"] = {
			range = {x = 3,y = 26},
			speed = 30,
			loop = true
		},
		["mine"] = {
			range = {x = 53,y = 77},
			speed = 30,
			loop = true
		},
		["attack"] = {
			range = {x = 53,y = 77},
			speed = 30,
			loop = true
		}
	},
--[[ For reference, the player animations are:
local anims = {
	stand     = {range = {x = 0  , y = 0  }, speed = 30},
	sit       = {range = {x = 1  , y = 1  }, speed = 30},
	lay       = {range = {x = 2  , y = 2  }, speed = 30},
	walk      = {range = {x = 3  , y = 26 }, speed = 30},
	walk_mine = {range = {x = 28 , y = 52 }, speed = 30},
	mine      = {range = {x = 53 , y = 77 }, speed = 30},
	swim_mine = {range = {x = 78 , y = 108}, speed = 28},
	swim_up   = {range = {x = 109, y = 133}, speed = 28},
	swim_down = {range = {x = 134, y = 158}, speed = 28},
	wave      = {range = {x = 159, y = 171}, speed = 34}
}
--]]
	gold = 1,
	gold_max = 3,
	xp = 2,
	xp_max = 3,
	max_speed = 5,
	jump_height = 3.5,
	view_range = 20,
	attack={
		range = 3,
		interval = 1,
		damage_groups = {fleshy = 5}
	},
		groups = {unbreakable = 1, loadme = 1, overrides_pointable = 1},
		on_construct = function(pos)

		end,
		on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
			--if def.on_punch and def.on_punch(pos, node, puncher, ...) then
			--	return
			--end
					minetest.log("action",
			("player '%s' punches npcmob '%s'"):format(puncher:get_player_name() or "!", def.npcname)
		)

			local thepuncher = puncher
			--mobkit_custom.on_punch(pos, node, puncher, ...)
			self.hostility = mobkit.recall(self, "hostility")

			if def.hit_replies and thepuncher and thepuncher:is_player() then
				if self.hostility < 1 then minetest.chat_send_player(thepuncher:get_player_name(), ("<%s> "):format(prettify(name))..def.hit_replies[math.random(1, #def.hit_replies)]) end
			end
			self.hostility = self.hostility + 1
			mobkit.remember(self, "hostility", self.hostility)
			if self.hostility > 0 then
				mobkit.remember(self, "standddown", nil)
			end
			mobkit_custom.on_punch(self, puncher, time_from_last_punch, tool_capabilities, dir)
		end,
		on_rightclick = function(self, clicker)--(pos, node, clicker, itemstack, pointed_thing)
			minetest.log("action",
			("right click on npcmob '%s'"):format(def.npcname))
			if not clicker or not clicker:is_player() then return end

			local pname = clicker:get_player_name()

			if not context[pname] or context[pname].npcdef.npcname ~= name then
				context[pname] = {
					tab = 1,
					npcdef = def,
					quest = 1,
					npcself = self
				}
				if def.convos then minetest.log("info", ("debug convos: '%s'"):format(dump(def.convos))) 
				else minetest.log("info", ("missing convos in def: '%s'"):format(dump(def)))
				end
			else context[pname].npcself = self
			end
			
			if def.convos then minetest.log("action", ("debug convos: '%s'"):format(dump(def.convos))) 
			else minetest.log("action", ("missing convos in def: '%s'"):format(dump(def))) end

			vk_quests.show_npc_form(pname, context[pname])
		end,
		armor_groups = {fleshy=10},
}
)
end

register_npcmob("Hrothgar_the_Mercenary", {
	texture = "vk_npcs_guard.png", -- TODO change this texture and actually use it in register npcmob.
	hit_replies = default_hit_replies,
	convos = {
		--Quests = {
		--	"kill_spider:spider",
		--},
		Talk = {
			{ condition = {operation = "not", values = {"following"}},
				who = NPC,
				line = {"I can work as a mercenary if that's your thing. 5 gold.","You look like you could use some protection... For just 5 gold.","I'd love to join you on your adventures but I'm a little short on cash.  You got, say, 5 gold to spare?"},
				talk = {
						{who = PLAYER, line = {"Sure, I could use the company, all those days trudging the wilderness.", "Welcome to the gang!", "Yeah, the more the merrier!", "Yes please. I was hoping you'd say that.", "You got yourself a deal.", "Consider yourself hired."}, talk = {{ condition = {operation = "greaterthan", values = {"player.gold",4}}, who = NPC, line = {"Thanks. You won't regret this.", "I am at your service.", "Let's get going then."}, action = "follow", cost = 5}, { condition = {operation = "lessthan", values = {"player.gold",5}}, who = NPC, line = {"Why not ask me again when you have the money?","Maybe check your gold BEFORE embarrassing yourself next time!","I don't offer credit, sorry. Need 5 gold up front.","Where's my money?"}}}},
						{who = PLAYER, line = {"No thanks.","I work alone.","I am not interested."}, talk = {who = NPC, line = {"Your loss.","As you wish.","Some other time perhaps.","Let me know if you change your mind.","Fine."}}},
						{who = PLAYER, line = {"I don't have 5 gold.","Sorry, I can't afford it."}, talk = {who = NPC, line = {"Why not ask me again when you have the money?","Some other time perhaps.","Let me know if you change your mind."}}}
					}
			},
			{ condition = {operation = "if", values = {"following"}},
				who = PLAYER,
				line = {"Quit following me around.","The time has come for us to go our separate ways."},
				talk = {
					{who = NPC, line = {"It has been a pleasure.", "Farewell then.", "Until we meet again.", "Until next time.", "Goodbye.", action = "nofollow"}}
				}
			},
			{ condition = {operation = "and", values = {"following","attacking"}},--subconditions={{operation="if" values={"following"}},{operation="if" values={"attacking"}}}, = "attacking",
				who = PLAYER,
				line = {"Stand down.", "Disengage."},
				talk = {
					{who = NPC, line = {"Yes Sir.", "Very well.", action = "noattack"}}
				}
			}
		}
	}
})

register_npcmob("tavern_keeper", {
	texture = "vk_npcs_tavern_keeper.png",
	hit_replies = default_hit_replies,
	convos = {
		--Quests = {
		--	"kill_spider:spider",
		--},
		Talk = {
			{ 	who = NPC,
				line = {"Ignore what those guards tell you about me. Would you like a drink?"},
				talk = {
						{who = PLAYER, line = {"Yes please!"}, talk = {{ condition = {operation = "greaterthan", values = {"player.gold",0}}, who = NPC, line = {"Enjoy your drink, Sir."}, action = "givedrink", cost = 1}, { condition = {operation = "lessthan", values = {"player.gold",1}}, who = NPC, line = {"Why not ask me again when you have the money?","Maybe check your gold BEFORE embarrassing yourself next time!","I don't offer credit, sorry. Need 1 gold up front.","Where's my money?"}}}},
						{who = PLAYER, line = {"No thanks.","I am not thirsty.","I am not interested."}, talk = {who = NPC, line = {"Your loss.","As you wish.","Some other time perhaps.","Let me know if you change your mind.","Fine."}}},
						{who = PLAYER, line = {"I don't have 1 gold.","Sorry, I can't afford it."}, talk = {who = NPC, line = {"Why not ask me again when you have the money?","Some other time perhaps.","Let me know if you change your mind."}}}
					}
			}
		}

	}
})

-- Add a follower near the tavern keepers:

local function register_location_markers(name)
	minetest.register_node(modname..":"..name.."_marker", {
		drawtype = "airlike",
		walkable = false,
		pointable = false,
		buildable_to = false,
		paramtype = "light",
		sunlight_propagates = true,
		groups = {location_marker = 1},
	})
end

register_location_markers("tavern")

-- This was an idea for adding stuff by the tavern keeper
minetest.register_lbm({
	label = "Place tavern npcs",
	name = modname..":place_tavern_npcs",
	nodenames = {modname..":tavern_marker"},
	run_at_every_load = true,
	action = function(pos, node)
		minetest.log("info", "lbm function called for tavern keeper.")

		-- This will run every time the tavern activated
			
		local keeperexists = false
		local objs_in_area = minetest.get_objects_inside_radius(pos, NPC_SPAWN_RADIUS+5)

		for key, obj in pairs(objs_in_area) do
			if not obj:is_player() and obj:get_luaentity().name == "vk_npcs:tavern_keeper" then
				keeperexists = true
				local keeperpos = obj:getpos()
				minetest.log("info", "Found an existing tavern keeper nearby at: " .. keeperpos.x .. ", " .. keeperpos.y .. ", " .. keeperpos.z .. " Marker is at: " .. dump(pos) .. ".")
				break
			end
		end
		if not keeperexists then
				-- Add her back as an npcmob that can walk around
				minetest.add_entity({x = pos.x, y = (pos.y - 4 + 1), z = pos.z}, "vk_npcs:tavern_keeper")
		end
	end
})
minetest.log("info", "lbm function registered for tavern keeper.")

