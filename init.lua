local mq = require('mq')
local imgui = require('ImGui')

-- Configuration
local clericdistance = 30  -- Distance to stop dragging if a cleric is near the corpse
local mindistance = 10     -- Minimum distance to grab a corpse
local maxdistance = 100    -- Maximum distance to grab a corpse
local maxcorpses = 4       -- Maximum number of corpses to drag at one time

-- Corpses being dragged
local draggedCorpses = {}

-- Script state variable
local isPaused = false

-- Helper function to check if a corpse still exists and has valid properties
local function validateCorpse(corpse)
    if not corpse or not corpse.ID() then
        return false  -- Corpse does not exist
    end

    local corpseX = corpse.X()
    local corpseY = corpse.Y()

    -- If any of these values are nil, the corpse likely no longer exists
    if not corpseX or not corpseY then
        return false
    end

    return true  -- Corpse exists and has valid properties
end

-- Function to check if the cleric is in the group or raid
local function isClericInGroupOrRaid(clericName)
    local groupSize = mq.TLO.Group.Members() or 0
    for i = 1, groupSize do
        local groupMemberName = mq.TLO.Group.Member(i).Name()
        if groupMemberName == clericName then
            return true
        end
    end

    local raidSize = mq.TLO.Raid.Members() or 0
    for i = 1, raidSize do
        local raidMemberName = mq.TLO.Raid.Member(i).Name()
        if raidMemberName == clericName then
            return true
        end
    end

    return false  -- Cleric is not in the group or raid
end

-- Function to check if the character running the script is in a group or raid
local function isInGroupOrRaid()
    local inRaid = mq.TLO.Raid.Members() > 0  -- Check if the character is in a raid
    local inGroup = mq.TLO.Me.Grouped()        -- Check if the character is in a group
    return inRaid, inGroup
end

-- Function to check if a corpse belongs to the dragger (i.e., the character running the script)
local function isOwnCorpse(corpse)
    local myName = mq.TLO.Me.Name() .. "'s corpse"  -- Append "'s corpse" to the player's name
    return corpse.CleanName() == myName  -- Compare the corpse's clean name with the dragger's name
end

-- Helper function to check if a cleric in the group or raid is near the corpse
local function isClericNearCorpse(corpse)
    -- Validate the corpse's existence
    if not validateCorpse(corpse) then
        print("Corpse no longer exists, removing from draggedCorpses.")
        draggedCorpses[corpse.ID()] = nil
        return false
    end

    local corpseX = corpse.X()
    local corpseY = corpse.Y()

    -- Find clerics near the corpse's position, not the dragger's
    local clerics = mq.TLO.SpawnCount(string.format('pc class cleric loc %.2f %.2f radius %d', corpseX, corpseY, clericdistance))()

    if clerics > 0 then
        for i = 1, clerics do
            local cleric = mq.TLO.NearestSpawn(i .. string.format(',pc class cleric loc %.2f %.2f radius %d', corpseX, corpseY, clericdistance))
            local clericName = cleric.CleanName()

            if isClericInGroupOrRaid(clericName) then
                local clericX = cleric.X()
                local clericY = cleric.Y()

                if clericX and clericY and corpseX and corpseY then
                    local deltaX = corpseX - clericX
                    local deltaY = corpseY - clericY
                    local manualDistance = math.sqrt(deltaX^2 + deltaY^2)

                    if manualDistance <= clericdistance then
                        return true  -- A cleric in the group/raid is too close to the corpse
                    end
                end
            end
        end
    end

    return false  -- No clerics are near the corpse
end

-- Function to check if a corpse belongs to a group or raid member
local function isCorpseFromGroupOrRaid(corpse, inRaid, inGroup)
    local corpsename = corpse.CleanName()  -- Get the full corpse name
    local corpseadd = "'s corpse"  -- Used for name comparison

    -- Debug: Print the corpse name
    print("Corpse Name: " .. corpsename)

    -- Always allow dragging the dragger's own corpse
    if isOwnCorpse(corpse) then
        print("Dragging own corpse")
        return true
    end

    -- If the character is in a raid, check against raid members' corpse names
    if inRaid then
        local raidSize = mq.TLO.Raid.Members() or 0
        for i = 1, raidSize do
            local raidMemberName = mq.TLO.Raid.Member(i).Name() .. corpseadd
            if raidMemberName == corpsename then
                print("Corpse belongs to a raid member")
                return true
            end
        end
    -- If the character is not in a raid but is in a group, check against group members' corpse names
    elseif inGroup then
        local groupSize = mq.TLO.Group.Members() or 0
        for i = 1, groupSize do
            local groupMemberName = mq.TLO.Group.Member(i).Name() .. corpseadd
            if groupMemberName == corpsename then
                print("Corpse belongs to a group member")
                return true
            end
        end
    end

    return false  -- The corpse does not belong to a group or raid member
end

-- Main function to drag the corpse if no cleric is near
local function drag(corpse, dragname)
    -- Validate the corpse's existence before continuing
    if not validateCorpse(corpse) then
        print("Corpse no longer exists, removing from draggedCorpses.")
        draggedCorpses[corpse.ID()] = nil
        return
    end

    -- Determine if the character is in a raid or group
    local inRaid, inGroup = isInGroupOrRaid()

    -- Verify that the corpse belongs to a group or raid member, or is the dragger's own corpse
    if not isCorpseFromGroupOrRaid(corpse, inRaid, inGroup) then
        return
    end

    -- Always check if any clerics are near the corpse, regardless of the dragger's position
    local clericNearCorpse = isClericNearCorpse(corpse)

    -- If a cleric is near the corpse, do not proceed with dragging
    if clericNearCorpse then
        print("Cleric too close to corpse", dragname, "removing from draggedCorpses")
        draggedCorpses[corpse.ID()] = nil
        return
    end

    local target_distance = mq.TLO.Target.Distance()
    local current_target_name = mq.TLO.Target.Name()

    -- Check if the target is nil or if the target's name doesn't match the corpse name
    if target_distance == nil or current_target_name ~= corpse.Name() then
        -- Attempt to target the corpse by ID
        mq.cmdf('/target id %d', corpse.ID())
        mq.delay(100)

        -- Refresh the target name and distance
        current_target_name = mq.TLO.Target.Name()
        target_distance = mq.TLO.Target.Distance()

        -- If targeting failed, remove the corpse from the list
        if current_target_name == "" then
            print("Failed to target corpse", dragname, "removing from draggedCorpses")
            draggedCorpses[corpse.ID()] = nil
            return
        end
    end

    -- Proceed with dragging only if distance is within the allowed range
    if target_distance and target_distance <= maxdistance and target_distance >= mindistance then
        mq.cmd('/squelch /corpse')  -- Attempt to drag the corpse
        mq.delay(100)  -- Delay between dragging actions to avoid spamming
    end
end

-- Function to check and drag multiple corpses
local function dragcheck()
    local corpsecount = mq.TLO.SpawnCount('pccorpse radius ' .. maxdistance)() or 0  -- Ensure corpsecount is a valid number
    local activeDraggingCount = 0  -- Ensure activeDraggingCount is initialized to 0
    
    -- Count currently dragged corpses
    for _, isDragging in pairs(draggedCorpses) do
        if isDragging then
            activeDraggingCount = activeDraggingCount + 1
        end
    end

    if corpsecount >= 1 then  -- Ensure corpsecount is valid before comparison
        for i = 1, corpsecount do
            -- If we are already dragging the maximum number of corpses, break the loop
            if activeDraggingCount >= maxcorpses then break end

            local corpse_spawn = mq.TLO.NearestSpawn(i .. ',pccorpse radius ' .. maxdistance)
            if corpse_spawn and corpse_spawn.ID() and not draggedCorpses[corpse_spawn.ID()] then
                -- Validate the corpse before dragging it
                if not validateCorpse(corpse_spawn) then
                    print("Corpse is invalid, skipping.")
                    goto continue
                end

                local corpsename = corpse_spawn.CleanName()
                local corpseid = corpse_spawn.ID()

                -- Add the corpse to the list of dragged corpses
                draggedCorpses[corpseid] = true
                activeDraggingCount = activeDraggingCount + 1  -- Increase the count of active drags

                -- Pass the corpse object directly to drag
                drag(corpse_spawn, corpsename)
            end
            ::continue::
        end
    end

    -- Continue dragging the corpses that are still in the list
    for corpseid, isDragging in pairs(draggedCorpses) do
        if isDragging then
            local corpse_spawn = mq.TLO.Spawn(string.format("id %d", corpseid))
            -- If the corpse disappears, remove it from the list
            if not validateCorpse(corpse_spawn) then
                print("Corpse with ID", corpseid, "disappeared, removing from draggedCorpses")
                draggedCorpses[corpseid] = nil
            else
                drag(corpse_spawn, corpse_spawn.CleanName())  -- Continue dragging if valid
            end
        end
    end
end

-- ImGui function to render the Pause/Unpause and END buttons with a default size
local function corpsedragGUI()
    -- Set the default window size (width, height)
    imgui.SetNextWindowSize(120, 90)  -- Example: 300 width, 150 height

    imgui.Begin('CorpseDrag')  -- Create a window titled 'CorpseDrag'

    -- Pause/Unpause Button
    if isPaused then
        if imgui.Button('UNPAUSE') then
            isPaused = false
        end
    else
        if imgui.Button('PAUSE') then
            isPaused = true
        end
    end

    -- END Button to stop the Lua script
    if imgui.Button('END') then
        mq.cmd('/lua stop corpsedrag')  -- Send command to stop the script
    end

    imgui.End()  -- End the window
end

-- Initialize ImGui and render the button
mq.imgui.init('PauseControl', corpsedragGUI)

-- Entry point for script execution
local function main()
    while true do
        if not isPaused then
            dragcheck()
        end
        mq.delay(100)  -- Adjust delay to control how often dragging is checked
    end
end

main()