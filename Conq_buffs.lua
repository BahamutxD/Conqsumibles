-- Conq_buffs.lua
-- Minimal CQ_Buffs table for the standalone logger.
-- Contains only the entries referenced by Conq_raidlog.lua:
--   - type = "wepbuffonly"  (weapon enchants / oils / stones / poisons)
--   - consumables checked via CQ_Log_CheckPlayerBuff (spellId identifiers)
-- Does NOT include class buff display rows, auras, or debuffs.
-- buffFunc is stubbed to nil — it's only used by the RABuffs UI, not the logger.

CQ_Buffs = {

    -- -----------------------------------------------------------------------
    -- Weapon Enchants / Oils / Stones  (type = "wepbuffonly")
    -- The logger uses .type and .useOn from these entries.
    -- -----------------------------------------------------------------------
    brillmanaoil         = { type = "wepbuffonly", useOn = "weapon",   name = "Brilliant Mana Oil",                   identifiers = { }, itemId = 20748 },
    brillmanaoiloh       = { type = "wepbuffonly", useOn = "weaponOH", name = "Brilliant Mana Oil (offhand)",         identifiers = { }, itemId = 20748 },
    lessermanaoil        = { type = "wepbuffonly", useOn = "weapon",   name = "Lesser Mana Oil",                      identifiers = { }, itemId = 20747 },
    lessermanaoiloh      = { type = "wepbuffonly", useOn = "weaponOH", name = "Lesser Mana Oil (offhand)",            identifiers = { }, itemId = 20747 },
    blessedwizardoil     = { type = "wepbuffonly", useOn = "weapon",   name = "Blessed Wizard Oil",                   identifiers = { }, itemId = 23123 },
    blessedwizardoiloh   = { type = "wepbuffonly", useOn = "weaponOH", name = "Blessed Wizard Oil (offhand)",         identifiers = { }, itemId = 23123 },
    brilliantwizardoil   = { type = "wepbuffonly", useOn = "weapon",   name = "Brilliant Wizard Oil",                 identifiers = { }, itemId = 20749 },
    brilliantwizardoiloh = { type = "wepbuffonly", useOn = "weaponOH", name = "Brilliant Wizard Oil (offhand)",       identifiers = { }, itemId = 20749 },
    wizardoil            = { type = "wepbuffonly", useOn = "weapon",   name = "Wizard Oil",                           identifiers = { }, itemId = 20750 },
    wizardoiloh          = { type = "wepbuffonly", useOn = "weaponOH", name = "Wizard Oil (offhand)",                 identifiers = { }, itemId = 20750 },
    shadowoil            = { type = "wepbuffonly", useOn = "weapon",   name = "Shadow Oil",                           identifiers = { }, itemId = 3824 },
    shadowoiloh          = { type = "wepbuffonly", useOn = "weaponOH", name = "Shadow Oil (offhand)",                 identifiers = { }, itemId = 3824 },
    frostoil             = { type = "wepbuffonly", useOn = "weapon",   name = "Frost Oil",                            identifiers = { }, itemId = 3829 },
    frostoiloh           = { type = "wepbuffonly", useOn = "weaponOH", name = "Frost Oil (offhand)",                  identifiers = { }, itemId = 3829 },
    consecratedstone     = { type = "wepbuffonly", useOn = "weapon",   name = "Consecrated Sharpening Stone",         identifiers = { }, itemId = 23122 },
    consecratedstoneoh   = { type = "wepbuffonly", useOn = "weaponOH", name = "Consecrated Sharpening Stone (offhand)", identifiers = { }, itemId = 23122 },
    denseweightstone     = { type = "wepbuffonly", useOn = "weapon",   name = "Dense Weightstone",                    identifiers = { }, itemId = 12643 },
    denseweightstoneoh   = { type = "wepbuffonly", useOn = "weaponOH", name = "Dense Weightstone (offhand)",          identifiers = { }, itemId = 12643 },
    densesharpeningstone     = { type = "wepbuffonly", useOn = "weapon",   name = "Dense Sharpening Stone",           identifiers = { }, itemId = 12404 },
    densesharpeningstoneoh   = { type = "wepbuffonly", useOn = "weaponOH", name = "Dense Sharpening Stone (offhand)", identifiers = { }, itemId = 12404 },
    elementalsharpeningstone     = { type = "wepbuffonly", useOn = "weapon",   name = "Elemental Sharpening Stone",   identifiers = { }, itemId = 18262 },
    elementalsharpeningstoneoh   = { type = "wepbuffonly", useOn = "weaponOH", name = "Elemental Sharpening Stone (offhand)", identifiers = { }, itemId = 18262 },

    -- Poisons (wepbuffonly - no buff bar icon to scan)
    deadlypoison         = { type = "wepbuffonly", useOn = "weapon",   name = "Deadly Poison",                        identifiers = { }, itemId = 20844 },
    deadlypoisonoh       = { type = "wepbuffonly", useOn = "weaponOH", name = "Deadly Poison (offhand)",              identifiers = { }, itemId = 20844 },
    instantpoison        = { type = "wepbuffonly", useOn = "weapon",   name = "Instant Poison",                       identifiers = { }, itemId = 8928 },
    instantpoisonoh      = { type = "wepbuffonly", useOn = "weaponOH", name = "Instant Poison (offhand)",             identifiers = { }, itemId = 8928 },
    mindnumbingpoison    = { type = "wepbuffonly", useOn = "weapon",   name = "Mind-numbing Poison",                  identifiers = { }, itemId = 9186 },
    mindnumbingpoisonoh  = { type = "wepbuffonly", useOn = "weaponOH", name = "Mind-numbing Poison (offhand)",        identifiers = { }, itemId = 9186 },
    woundpoison          = { type = "wepbuffonly", useOn = "weapon",   name = "Wound Poison",                         identifiers = { }, itemId = 10922 },
    woundpoisonoh        = { type = "wepbuffonly", useOn = "weaponOH", name = "Wound Poison (offhand)",               identifiers = { }, itemId = 10922 },
    cripplingpoison      = { type = "wepbuffonly", useOn = "weapon",   name = "Crippling Poison",                     identifiers = { }, itemId = 3776 },
    cripplingpoisonoh    = { type = "wepbuffonly", useOn = "weaponOH", name = "Crippling Poison (offhand)",           identifiers = { }, itemId = 3776 },

    -- -----------------------------------------------------------------------
    -- Consumables tracked by buff bar polling (CheckPlayerBuff)
    -- identifiers[].spellId is used for reliable matching via UnitBuff()
    -- -----------------------------------------------------------------------

    -- Flasks
    flask         = { name = "Flask of Supreme Power",        identifiers = { { tooltip = "Supreme Power",          texture = "INV_Potion_41",         spellId = 17628  } }, itemId = 13512 },
    titans        = { name = "Flask of the Titans",           identifiers = { { tooltip = "Flask of the Titans",    texture = "INV_Potion_62",         spellId = 17626  } }, itemId = 13510 },
    wisdom        = { name = "Flask of Distilled Wisdom",     identifiers = { { tooltip = "Distilled Wisdom",       texture = "INV_Potion_97",         spellId = 17627  } }, itemId = 13511 },
    chromaticres  = { name = "Flask of Chromatic Resistance", identifiers = { { tooltip = "Chromatic Resistance",   texture = "INV_Potion_48",         spellId = 17629  } }, itemId = 13513 },
    anyflask      = { name = "Any Flask",                     identifiers = {
        { tooltip = "Supreme Power",        texture = "INV_Potion_41", spellId = 17628 },
        { tooltip = "Distilled Wisdom",     texture = "INV_Potion_97", spellId = 17627 },
        { tooltip = "Flask of the Titans",  texture = "INV_Potion_62", spellId = 17626 },
        { tooltip = "Chromatic Resistance", texture = "INV_Potion_48", spellId = 17629 },
    } },

    -- Elixirs - Battle
    giants              = { name = "Elixir of the Giants",      identifiers = { { tooltip = "Elixir of the Giants",    texture = "INV_Potion_61",  spellId = 11405  } }, itemId = 9206 },
    mongoose            = { name = "Elixir of the Mongoose",    identifiers = { { tooltip = "Elixir of the Mongoose",  texture = "INV_Potion_32",  spellId = 17538  } }, itemId = 13452 },
    greateragilityelixir= { name = "Elixir of Greater Agility", identifiers = { { tooltip = "Greater Agility",         texture = "INV_Potion_93",  spellId = 11334  } }, itemId = 9187 },
    agilityelixir       = { name = "Elixir of Agility",         identifiers = { { tooltip = "Agility",                 texture = "INV_Potion_93",  spellId = 11328  } }, itemId = 8949 },
    firewater           = { name = "Winterfall Firewater",      identifiers = { { tooltip = "Winterfall Firewater",    texture = "INV_Potion_92",  spellId = 17038  } }, itemId = 12820 },
    demonslaying        = { name = "Elixir of Demonslaying",    identifiers = { { tooltip = "Elixir of Demonslaying",  texture = "SPELL_HOLY_RETRIBUTIONAURA", spellId = 11406  } }, itemId = 9224 },

    -- Elixirs - Guardian
    elixirfortitude = { name = "Elixir of Fortitude",       identifiers = { { tooltip = "Health II",      texture = "INV_Potion_44",  spellId = 3593   } }, itemId = 3825 },
    supdef          = { name = "Elixir of Superior Defense", identifiers = { { tooltip = "Greater Armor",  texture = "INV_Potion_86",  spellId = 11348  } }, itemId = 13445 },

    -- Elixirs - Spell Power
    greaterarcane       = { name = "Greater Arcane Elixir",          identifiers = { { tooltip = "Greater Arcane Elixir",     texture = "INV_Potion_25",  spellId = 17539  } }, itemId = 13454 },
    greaterfirepower    = { name = "Elixir of Greater Firepower",    identifiers = { { tooltip = "Greater Firepower",          texture = "INV_Potion_60",  spellId = 26276  } }, itemId = 21546 },
    greaternaturepower  = { name = "Elixir of Greater Nature Power", identifiers = { { tooltip = "Greater Nature Power",       texture = "Spell_Nature_SpiritArmor", spellId = 45988  } }, itemId = 50237 },
    shadowpower         = { name = "Elixir of Shadow Power",         identifiers = { { tooltip = "Shadow Power",               texture = "INV_Potion_46",  spellId = 11474  } }, itemId = 9264 },
    frostpower          = { name = "Elixir of Frost Power",          identifiers = { { tooltip = "Frost Power",                texture = "INV_Potion_03",  spellId = 21920  } }, itemId = 17708 },
    arcaneelixir        = { name = "Arcane Elixir",                  identifiers = { { tooltip = "Arcane Elixir",              texture = "INV_Potion_30",  spellId = 11390  } }, itemId = 9155 },
    firepowerelixir     = { name = "Elixir of Firepower",            identifiers = { { tooltip = "Fire Power",                 texture = "INV_Potion_60",  spellId = 7844   } }, itemId = 6373 },
    dreamshard          = { name = "Dreamshard Elixir",              identifiers = { { tooltip = "Dreamshard Elixir",          texture = "INV_Potion_25",  spellId = 45427  } }, itemId = 61224 },
    dreamtonic          = { name = "Dreamtonic",                     identifiers = { { tooltip = "Dreamtonic",                 texture = "INV_Potion_114", spellId = 45489  } }, itemId = 61423 },
    elixirofthesages    = { name = "Elixir of the Sages",            identifiers = { { tooltip = "Elixir of the Sages",        texture = "INV_Potion_29",  spellId = 17535  } }, itemId = 13447 },
    greaterarcanepower  = { name = "Elixir of Greater Arcane Power", identifiers = { { tooltip = "Greater Arcane Power",       texture = "Spell_Holy_FlashHeal", spellId = 56545  } }, itemId = 55048 },
    greaterfrostpower   = { name = "Elixir of Greater Frost Power",  identifiers = { { tooltip = "Greater Frost Power",        texture = "INV_Potion_03",  spellId = 56544  } }, itemId = 55046 },

    -- Protection Potions (Greater only)
    greaterarcanepot= { name = "Greater Arcane Protection Potion", identifiers = { { tooltip = "Arcane Protection",   texture = "Spell_Holy_PrayerOfHealing02", spellId = 17549  } }, itemId = 13461 },
    greaternaturepot= { name = "Greater Nature Protection Potion", identifiers = { { tooltip = "Nature Protection",   texture = "Spell_Nature_SpiritArmor",     spellId = 17546  } }, itemId = 13458 },
    greatershadowpot= { name = "Greater Shadow Protection Potion", identifiers = { { tooltip = "Shadow Protection",   texture = "Spell_Shadow_RagingScream",    spellId = 17548  } }, itemId = 13459 },
    greaterfirepot  = { name = "Greater Fire Protection Potion",   identifiers = { { tooltip = "Fire Protection",     texture = "Spell_Fire_FireArmor",          spellId = 17543  } }, itemId = 13457 },
    greaterfrostpot = { name = "Greater Frost Protection Potion",  identifiers = { { tooltip = "Frost Protection",    texture = "Spell_Frost_FrostArmor02",      spellId = 17544  } }, itemId = 13456 },
    greaterholypot  = { name = "Greater Holy Protection Potion",   identifiers = { { tooltip = "Holy Protection",     texture = "Spell_Holy_BlessingOfProtection", spellId = 17545  } }, itemId = 13460 },
    frozenrune      = { name = "Frozen Rune",                      identifiers = { { tooltip = "Fire Protection",     texture = "Spell_Fire_MasterOfElements",  spellId = 29432  } }, itemId = 22682 },

    -- Utility Potions
    mageblood          = { name = "Mageblood Potion",               identifiers = { { tooltip = "Mana Regeneration",   texture = "INV_Potion_45",  spellId = 24363  } }, itemId = 20007 },
    restorativepotion  = { name = "Restorative Potion",             identifiers = { { tooltip = "Restoration",          texture = "Spell_Holy_DispelMagic", spellId = 11359  } }, itemId = 9030 },
    freeactionpotion   = { name = "Free Action Potion",             identifiers = { { tooltip = "Free Action",          texture = "INV_Potion_04",  spellId = 6615   } }, itemId = 5634 },
    limitinvulpotion   = { name = "Limited Invulnerability Potion", identifiers = { { tooltip = "Invulnerability",      texture = "INV_Potion_62",  spellId = 3169  } } },

    -- Zanza
    spiritofzanza   = { name = "Spirit of Zanza",    identifiers = { { tooltip = "Spirit of Zanza",    texture = "INV_Potion_30", spellId = 24382  } }, itemId = 20079 },
    swiftnessofzanza= { name = "Swiftness of Zanza", identifiers = { { tooltip = "Swiftness of Zanza", texture = "INV_Potion_31", spellId = 24383  } }, itemId = 20081 },
    sheenofzanza    = { name = "Sheen of Zanza",     identifiers = { { tooltip = "Sheen of Zanza",     texture = "INV_Potion_29", spellId = 24417  } }, itemId = 20080 },

    -- Juju
    jujupower   = { name = "Juju Power",  identifiers = { { tooltip = "Juju Power",  texture = "INV_Misc_MonsterScales_11", spellId = 16323  } }, itemId = 12451 },
    jujumight   = { name = "Juju Might",  identifiers = { { tooltip = "Juju Might",  texture = "INV_Misc_MonsterScales_07", spellId = 16329  } }, itemId = 12460 },
    jujuchill   = { name = "Juju Chill",  identifiers = { { tooltip = "Juju Chill",  texture = "INV_Misc_MonsterScales_09", spellId = 16325  } }, itemId = 12457 },
    jujuflurry  = { name = "Juju Flurry", identifiers = { { tooltip = "Juju Flurry", texture = "INV_Misc_MonsterScales_17", spellId = 16322  } }, itemId = 12450 },
    jujuescape  = { name = "Juju Escape", identifiers = { { tooltip = "Juju Escape", texture = "INV_Misc_MonsterScales_17", spellId = 16321  } }, itemId = 12459 },
    jujuember   = { name = "Juju Ember",  identifiers = { { tooltip = "Juju Ember",  texture = "INV_Misc_MonsterScales_15", spellId = 16326  } }, itemId = 12455 },
    jujuguile   = { name = "Juju Guile",  identifiers = { { tooltip = "Juju Guile",  texture = "INV_Misc_MonsterScales_13", spellId = 16327  } }, itemId = 12458 },

    -- Blasted Lands
    roids         = { name = "R.O.I.D.S.",              identifiers = { { tooltip = "Rage of Ages",        texture = "Spell_Nature_Strength",      spellId = 10667  } }, itemId = 8410 },
    scorpok       = { name = "Ground Scorpok Assay",    identifiers = { { tooltip = "Strike of the Scorpok", texture = "Spell_Nature_ForceOfNature", spellId = 10669  } }, itemId = 8412 },
    cerebralcortex= { name = "Cerebral Cortex Compound",identifiers = { { tooltip = "Infallible Mind",     texture = "Spell_Ice_Lament",           spellId = 10692  } }, itemId = 8423 },
    lungJuice     = { name = "Lung Juice Cocktail",     identifiers = { { tooltip = "Spirit of Boar",      texture = "Spell_Nature_Purge",         spellId = 10668  } }, itemId = 8411 },
    gizzardgum    = { name = "Gizzard Gum",             identifiers = { { tooltip = "Stamina of the Boar", texture = "Spell_Nature_Spiritarmor",   spellId = 10693  } }, itemId = 8424 },

    -- Food / Drink
    squid           = { name = "Grilled Squid",              identifiers = { { tooltip = "Increased Agility",       texture = "INV_Gauntlets_19",         spellId = 18192  } }, itemId = 13928 },
    nightfinsoup    = { name = "Nightfin Soup",              identifiers = { { tooltip = "Mana Regeneration",       texture = "Spell_Nature_ManaRegenTotem", spellId = 18194  } }, itemId = 13931 },
    tuber           = { name = "Runn Tum Tuber Surprise",   identifiers = { { tooltip = "Increased Intellect",     texture = "INV_Misc_Organ_03",        spellId = 22730  } }, itemId = 18254 },
    desertdumpling  = { name = "Smoked Desert Dumpling",    identifiers = { { tooltip = "Well Fed",                texture = "Spell_Misc_Food",           spellId = 24799  } }, itemId = 20452 },
    mushroomstam    = { name = "Hardened Mushroom",         identifiers = { { tooltip = "Increased Stamina",       texture = "INV_Boots_Plate_03",       spellId = 25661  } }, itemId = 51717 },
    tenderwolf      = { name = "Tender Wolf Steak",         identifiers = { { tooltip = "Well Fed",                texture = "Spell_Misc_Food",           spellId = 19710  } }, itemId = 18045 },
    sagefish        = { name = "Sagefish Delight",          identifiers = { { tooltip = "Mana Regeneration",       texture = "inv_misc_fish_21",          spellId = 25889  } }, itemId = 21217 },
    dragonbreathchili={ name = "Dragonbreath Chili",        identifiers = { { tooltip = "Dragonbreath Chili",      texture = "Spell_Fire_Incinerate",     spellId = 15852  } }, itemId = 12217 },
    gurubashigumbo  = { name = "Gurubashi Gumbo",           identifiers = { { tooltip = "Well Fed",                texture = "Spell_Misc_Food",           spellId = 46083  } }, itemId = 53015 },
    telabimmedley   = { name = "Tel'Abim Medley",           identifiers = { { tooltip = "Well Fed",                texture = "Spell_Misc_Food",           spellId = 57046  } }, itemId = 60978 },
    telabimdelight  = { name = "Tel'Abim Delight",          identifiers = { { tooltip = "Well Fed",                texture = "Spell_Misc_Food",           spellId = 57044  } }, itemId = 60977 },
    telabimsurprise = { name = "Tel'Abim Surprise",         identifiers = { { tooltip = "Well Fed",                texture = "Spell_Misc_Food",           spellId = 57042  } }, itemId = 60976 },
    gilneashotstew  = { name = "Gilneas Hot Stew",          identifiers = { { tooltip = "Well Fed",                texture = "Spell_Misc_Food",           spellId = 45628  } }, itemId = 84041 },
    gordokgreengrog = { name = "Gordok Green Grog",         identifiers = { { tooltip = "Gordok Green Grog",       texture = "INV_Drink_03",              spellId = 22789  } }, itemId = 18269 },
    rumseyrum       = { name = "Rumsey Rum Black Label",    identifiers = { { tooltip = "Rumsey Rum Black Label",  texture = "INV_Drink_04",              spellId = 25804 } } },
    merlot          = { name = "Medivh's Merlot",           identifiers = { { tooltip = "Increased Stamina",       texture = "INV_Drink_04",              spellId = 57106 } } },
    merlotblue      = { name = "Medivh's Merlot Blue Label",identifiers = { { tooltip = "Increased Intellect",     texture = "INV_Drink_04",              spellId = 57107 } } },
    herbalsalad     = { name = "Herbal Salad",              identifiers = { { tooltip = "Increased Healing Bonus", texture = "Spell_Nature_HealingWay",   spellId = 49553  } }, itemId = 83309 },

    -- Concoctions
    arcanegiants    = { name = "Concoction of the Arcane Giant",    identifiers = { { tooltip = "Concoction of the Arcane Giant",    texture = "inv_yellow_purple_elixir_2", spellId = 36931  } }, itemId = 47412 },
    emeraldmongoose = { name = "Concoction of the Emerald Mongoose",identifiers = { { tooltip = "Concoction of the Emerald Mongoose",texture = "inv_blue_gold_elixir_2",     spellId = 36928  } }, itemId = 47410 },
    dreamwater      = { name = "Concoction of the Dreamwater",      identifiers = { { tooltip = "Concoction of the Dreamwater",      texture = "inv_green_pink_elixir_1",    spellId = 36934  } }, itemId = 47414 },

    -- Explosives / Misc (no buff bar icon - tracked via chat/SPELL_GO only)
    goblinsapper    = { name = "Goblin Sapper Charge", identifiers = { }, itemId = 10646 },
    oilofimmolation = { name = "Oil of Immolation",    identifiers = { { tooltip = "Fire Shield", texture = "Spell_Fire_Immolation", spellId = 11350  } }, itemId = 8956 },
    bogling         = { name = "Bogling Root",         identifiers = { { tooltip = "Fury of the Bogling", texture = "Spell_Nature_Strength", spellId = 5665  } }, itemId = 5206 },
};
