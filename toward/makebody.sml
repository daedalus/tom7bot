(* This is a body editor for a new game, codename TOWARD.

   It allows (or will, when it's workin'?) to build a collection of
   bodies, each of which is a collection of fixtures (low-vertex
   convex polygons) in fixed relative positions. It probably needs
   to associate some kind of graphic with the body (which is just
   for the physics simulation), but that will have to wait for
   GL support.
*)

structure MakeBody =
struct

  open BDDMath
  open BDDOps
  infix 6 :+: :-: %-% %+% +++
  infix 7 *: *% +*: +*+ #*% @*:

  structure BDD = BDDWorld(
    type fixture_data = unit
    type body_data = string
    type joint_data = unit)
  open BDD
  exception MakeBody of string

  structure U = Util
  open SDL
  structure Util = U

  structure Font = FontFn 
  (val surf = Images.requireimage "font.png"
   val charmap =
       " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" ^
       "`-=[]\\;',./~!@#$%^&*()_+{}|:\"<>?" (* " *)
   val width = 9
   val height = 16
   val styles = 6
   val overlap = 1
   val dims = 3)

  val WIDTH = 1024
  val HEIGHT = 768
  val PIXELS_PER_METER = 50
  val METERS_PER_PIXEL = 1.0 / real PIXELS_PER_METER
  val screen = makescreen (WIDTH, HEIGHT)

  fun eprint s = TextIO.output (TextIO.stdErr, s)

  (* val () = SDL.show_cursor false *)

  fun tometers d = real d * METERS_PER_PIXEL
  fun toworld (xp, yp) =
      let
          val xp = xp - (WIDTH div 2)
          val yp = yp - (HEIGHT div 2)
      in
          (tometers xp, tometers yp)
      end

  val DRAW_NORMALS = false
  val DRAW_DISTANCES = true
  val DRAW_RAYS = true
  val DRAW_COLLISIONS = true

  structure GA = GrowArray

  type poly = vec2 GA.growarray
  type letter =
      (* Add graphics, ... *)
      { polys: poly GA.growarray }

  fun copyletter { polys } =
      { polys = GA.fromlist (map GA.copy (GA.tolist polys)) }
      handle Subscript => (eprint "copyletter"; raise Subscript)

  (* Only if they are structurally equal (order of polygons and
     vertices matters). Used to deduplicate undo state. *)
  local exception NotEqual
  in
      fun lettereq ({ polys = ps }, { polys = pps }) =
          let in
              if GA.length ps <> GA.length pps
              then raise NotEqual
              else ();
              Util.for 0 (GA.length ps - 1) 
              (fn i =>
               let val p = GA.sub ps i
                   val pp = GA.sub pps i
               in
                   if GA.length p <> GA.length pp
                   then raise NotEqual
                   else ();
                   Util.for 0 (GA.length p - 1)
                   (fn j =>
                    if not (vec2eq (GA.sub p j, GA.sub pp j))
                    then raise NotEqual
                    else ())
               end);
              true
          end handle NotEqual => false
  end

  (* 0xRRGGBB *)
  fun hexcolor c =
      let
          val b = c mod 256
          val g = (c div 256) mod 256
          val r = ((c div 256) div 256) mod 256
      in
          SDL.color (Word8.fromInt r, 
                     Word8.fromInt g,
                     Word8.fromInt b,
                     0w255)
      end

     
  (* Put the origin of the world at WIDTH / 2, HEIGHT / 2.
     make the viewport show 8 meters by 6. *)
  fun topixels d = d * real PIXELS_PER_METER
  fun toscreen (xm, ym) =
      let
          val xp = topixels xm
          val yp = topixels ym
      in
          (Real.round xp + (WIDTH div 2),
           Real.round yp + (HEIGHT div 2))
      end

  fun vectoscreen v = toscreen (vec2xy v)
  fun screentovec (x, y) = vec2 (toworld (x, y))

  val PURPLE = hexcolor 0xFF00FF
  val RED = hexcolor 0xFF0000
  val WHITE = hexcolor 0xFFFFFF
  fun drawpoly (poly : poly) =
      let
          val num = GA.length poly
      in
          Util.for 0 (num - 1)
          (fn i =>
           let val i2 = if i = num - 1
                        then 0
                        else i + 1
               val (x, y) = vectoscreen (GA.sub poly i)
               val (xx, yy) = vectoscreen (GA.sub poly i2)
           in
               SDL.drawline (screen, x, y, xx, yy, WHITE)
           end)
      end

  (* Currently selected vertices. First index is the polygon,
     second is the vertex on that polygon. Often nil. *)
  val selected = ref nil : (int * int) list ref

  fun drawpolyvertices (sel : int list, poly : poly) =
      let
          val num = GA.length poly
      in
          Util.for 0 (num - 1)
          (fn i =>
           let 
               val (x, y) = vectoscreen (GA.sub poly i)
           in
               if List.exists (fn x => x = i) sel
               then SDL.drawcircle (screen, x, y, 3, RED)
               else SDL.drawcircle (screen, x, y, 2, PURPLE)
           end)
      end

  fun drawletter (letter as { polys, ... } : letter) =
      let
          val num = GA.length polys
      in
          Util.for 0 (num - 1)
          (fn i => drawpoly (GA.sub polys i));

          (* Draw vertices. *)
          Util.for 0 (num - 1)
          (fn i => drawpolyvertices (List.mapPartial 
                                     (fn (p, v) => if p = i then SOME v
                                                   else NONE) (!selected),
                                     GA.sub polys i));

          ()
      end

  exception Done

  val mousex = ref 0
  val mousey = ref 0
  val mousedown = ref false

  (* Yuck, can definitely do better than this. *)
  fun trivialpolygon v =
      GA.fromlist [vec2 (0.0, 1.0) :+: v,
                   vec2 (1.0, 0.0) :+: v,
                   vec2 (~0.5, ~0.5) :+: v]

  val undostate = UndoState.undostate () : letter UndoState.undostate

  val letter = ref { polys = GA.fromlist [trivialpolygon (vec2 (0.0, 0.0))] }

  (* Call before making a modification to the state. Keeps the buffer
     length from exceeding MAX_UNDO. Doesn't duplicate the state if it
     is already on the undo buffer. *)
  val MAX_UNDO = 100
  fun savestate () =
      let in
          (case UndoState.peek undostate of
               NONE => UndoState.save undostate (copyletter (!letter))
             | SOME prev =>
                   if lettereq (prev, !letter)
                   then ()
                   else UndoState.save undostate (copyletter (!letter)));
          UndoState.truncate undostate MAX_UNDO
      end

  (* Return the indices of the vertices closest to the point. *)
  (* XXX don't allow selection of two points on the same poly!
     They would have to be coincident though, so maybe we can just
     maintain that as a representation invariant. *)
  fun findclosestpoints v =
      (* PERF could use kd-tree but have to maintain it, which is expensive.
         Realistically there won't be more than a few hundred vertices. *)
      let
          (* Every point that goes in here will be exactly coincident. *)
          val best_dist = ref 999999999999.0
          val best_vs = ref (nil : (int * int) list)
      in
          GA.appi (fn (i, poly)  =>
                   GA.appi (fn (j, vertex) =>
                            let val d = distance_squared (v, vertex)
                            in
                                if d < !best_dist
                                then (best_dist := d;
                                      best_vs := [(i, j)])
                                else if Real.== (d, !best_dist)
                                     then (best_vs := (i, j) :: !best_vs)
                                     else ()
                            end) poly
                   ) (#polys (!letter));
          !best_vs
      end

  (* XXX *)
  fun drawmenu () =
      let
          val pfx = "^3Toward body editor^<: "
          val items = [("n", "new")]

      in
          Font.draw (screen, 0, 0, pfx);
          Font.draw (screen, WIDTH - 100, 0,
                     "^1" ^
                     Int.toString (UndoState.history_length undostate) ^ 
                     "^< undo ^1" ^
                     Int.toString (UndoState.future_length undostate))
      end

  fun draw () =
      let in
          drawletter (!letter);
          drawmenu ()
      end

  (* XXX do snapping if enabled. *)
  fun setvertex (pi, vi) vnew =
      let in
          (* Don't save undo every time, because then we have the whole history
             of dragging, which is silly. *)
          GA.update (GA.sub (#polys (!letter)) pi) vi vnew
      end

  fun mousemotion (x, y) =
      let in 
          mousex := x;
          mousey := y;
          if !mousedown
          then List.app (fn (i, j) => setvertex (i, j) (screentovec (x, y))) (!selected)
          else ()
      end

  fun leftmouse (x, y) =
      (* Currently, select the closest point. *)
      let in
          savestate ();
          mousedown := true;
          (* XXX should put some (small) limit on the absolute screen
             distance we allow for selection. *)
          selected := findclosestpoints (screentovec (x, y));
          (* Simulate mouse motion. *)
          mousemotion (x, y)
      end

  (* XXX require ctrl for undo/redo, etc. *)
  fun keydown SDLK_ESCAPE = raise Done
    | keydown SDLK_z =
      (* XXX shouldn't allow undo when dragging? *)
      (case UndoState.undo undostate of
           NONE => ()
         | SOME s => letter := copyletter s)
    | keydown SDLK_y =
      (case UndoState.redo undostate of
           NONE => ()
         | SOME s => letter := copyletter s)
    | keydown _ = ()

  fun events () =
      case pollevent () of
          NONE => ()
        | SOME evt =>
           case evt of
               E_Quit => raise Done
             | E_KeyDown { sym } => keydown sym
             | E_MouseMotion { state : mousestate, x : int, y : int, ... } =>
                   mousemotion (x, y)
             | E_MouseDown { button = 1, x, y, ... } => leftmouse (x, y)
             | E_MouseUp _ =>
                   let in
                       mousedown := false
                   end
             | _ => ()

  fun loop () =
      let in
          (* XXX don't need to continuously be drawing. *)          
          clearsurface (screen, color (0w255, 0w0, 0w0, 0w0));

          draw ();

          flip screen;

          events ();
          delay 0;
          loop ()
      end

  val () = Params.main0 "No arguments." loop
  handle e =>
      let in
          eprint ("unhandled exception " ^
                  exnName e ^ ": " ^
                  exnMessage e ^ ": ");
          (case e of
               BDDDynamics.BDDDynamics s => eprint s
             | BDDDynamicTree.BDDDynamicTree s => eprint s
             | BDDContactSolver.BDDContactSolver s => eprint s
             | BDDMath.BDDMath s => eprint s
             | MakeBody s => eprint s
             | _ => eprint "unknown");
          eprint "\nhistory:\n";
          app (fn l => eprint ("  " ^ l ^ "\n")) (Port.exnhistory e);
          eprint "\n"
      end
                   
end
