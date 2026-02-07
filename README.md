The mod transforms unstructured player actions 
into a clean, machine-readable logistics stream. 

By storing the unit_number (ID) of machines or chests, 
the path of each item can be tracked precisely. 

The system is a data source for complex evaluations 
or logistics statistics. 

logistics event: (when, who, what, where, object)

{
  tick = 12345,
    actor = { type = "player-hand", id = 1, name = "PlayerName"},
    action = "GIVE",
    source_or_target = { type = "assembling-machine-2", id = 67890, slot_name = "modules"},
    item = { name = "efficiency-module", quantity = 1, quality = "epic"}
}


The mod mainly serves to track players' activities in Factorio, such as moving materials around the world. 
I wrote the factory ledger — the accounting system — and, as in any factory, people often intervene manually. 
For example, employees may take something somewhere else in advance, which messes up the accounting. 
How can this be avoided in a factory? 
Employees often have a scanner that they use to scan items, which makes it possible to see what has been taken. 
As I didn't have that, I decided that I needed a kind of 'Big Brother' module that would allow me to recognise 
the player's activities and turn them into logistical events. This would enable me to see what really happened 
when they intervened manually, for example taking iron plates out of one place and putting them somewhere else. 
However, the accounting department also needs to be aware of this.
This means the Big Brother module observes the activity, generates an event and then you can make the appropriate 
accounting entry. This is standard practice in every company, so if you notice a change that hasn't been posted, 
it must be posted retrospectively.

The mod was created using AI mainly Claude - Gemini and DeepL (write)
