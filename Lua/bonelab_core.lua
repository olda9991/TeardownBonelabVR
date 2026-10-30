-- Bonelab style VR core
BONELAB = {}
BONELAB.hands = {left=nil, right=nil}
BONELAB.grabbed = {left=nil, right=nil}
BONELAB.climbing = false
BONELAB.weaponMode = false

function BONELAB.init()
    -- init hand physics
end

function BONELAB.tick()
    -- handle grabbing, climbing, weapon interaction
    local lgrip = InputDown('vr_lgrip')
    local rgrip = InputDown('vr_rgrip')
    if lgrip then
        BONELAB.tryGrab('left')
    else
        BONELAB.release('left')
    end
    if rgrip then
        BONELAB.tryGrab('right')
    else
        BONELAB.release('right')
    end
end

function BONELAB.tryGrab(side)
    if BONELAB.grabbed[side] then return end
    -- raycast from hand
    local hand = GetPlayerTransform()
    -- simplified grab
    BONELAB.grabbed[side] = true
end

function BONELAB.release(side)
    BONELAB.grabbed[side] = nil
end

function BONELAB.drawVRMenu()
    -- draw world space menus
    UiPush()
    UiTranslate(0,0)
    UiColor(1,1,1,1)
    UiText("BONELAB VR")
    UiPop()
end
