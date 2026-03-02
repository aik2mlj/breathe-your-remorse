#set text(size: 12pt)
#set par(justify: true)
#show link: underline

#let cline() = {
  v(-3pt)
  line(length: 100%, stroke: 0.7pt)
  v(-5pt)
}

#align(center)[
  = Breathe Your Remorse
  Lejun Min\
  ARTSTUDI 392 Final Proposal
]
#cline()

== Critical Reading Response
<critical-reading-response>

I chose the article
#link("https://www.cyberneticforests.com/news/how-to-read-an-ai-image")[#emph[How to Read an AI Image]]
and
#link(
  "https://electronicbookreview.com/publications/experiments-in-generating-cut-up-texts-with-commercial-ai/",
)[#emph[Experiments in Generating Cut-up texts with Commercial AI]]
for my critical reading. It is a novel perspective for me that we can
read AI images as the infographic of a dataset and training policies of
a certain model. Perhaps then, an art piece can also be used to probe
the tangent semantics of its reference, which can be the context,
dynamics, or origin of the referred symbol instead. The second reading
explores LLM composing cut-up texts like William S. Burroughs's. It is
interesting that the author took a detour when prompting the model, and
mentioned "the AI … was unable to prevent itself from smoothing the
results. It introduced verbs, adjectives and conjunctions that attempted
to explain the relationship between the nouns." There is this tension
between the eccentric approach the authors tried to instill, and the
smoothing "nature" of the autoregressive model.

From these conceptual frameworks, I learned that perhaps I can use AI as
an intervention rather than simply a compliant tool. I could put AI into
a scheme where it's nature runs against certain principles I defined.
From this conflict we could then get a glimpse of what's implied beyond
the notation.

== Project Proposal
<title-breathe-your-remorse-may-change-later>

As described from previous presentations, there will be AI agents
listening to the visitor's breath and singing, and respond with certain
choices they make. I will use multiple laptops as "fellow moderators",
but instead of complying with and accompanying the singing right away,
they will first record, and then echo back with the least similar clips
they recorded some moments ago. They form an anti-equilibrium system
which runs against the goal of finding peace. It manifests the
impermanent dynamics of one's audible breath, thus forcing the human
participant to hear and reconcile with their previous self. Being in the
same space, the agents will naturally record each other and echo back,
transmitting the initial input into a reverberating mixture that
gradually fades away. It resembles how our memories and accumulated
sentiment swell and ferment within us, which we have to learn to digest
and live with.

Tools used: audio programming with
#link("https://chuck.stanford.edu/")[ChucK], laptops, loudspeakers,
microphones.

Tools needed: I can borrow all these from my department. I may later add
the visual part, which potentially requires a projector.

Timeline of production:

- Week 7: prototype done
- Week 8: initial performance documentation and reflection
- Week 9: tweaking, feedback, and installation
