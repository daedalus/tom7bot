
structure Otolith =
struct

  exception Quit
  open Constants

  fun eprint s = TextIO.output(TextIO.stdErr, s ^ "\n")

  val fillscreen = _import "FillScreenFrom" private :
      Word32.word Array.array -> unit ;

  val ctr = ref 0
  val pixels = Array.array(WIDTH * HEIGHT, 0wxFFAAAAAA : Word32.word)
  val rc = ARCFOUR.initstring "anything"

  val tesselation = Tesselation.tesselation { x0 = 20, y0 = 20,
                                              x1 = WIDTH - 20, y1 = HEIGHT - 20 }

  val TESSELATIONLINES = Draw.mixcolor (0wxAA, 0wxAA, 0wx99, 0wxFF)
  val TESSELATIONNODES = Draw.mixcolor (0wx33, 0wxAA, 0wxFF, 0wxFF)

  (* PERF: draws edges twice *)
  fun drawtesselation () =
      let
          val triangles = Tesselation.triangles tesselation
          val nodes = Tesselation.nodes tesselation

          fun drawnode n =
              let val (x, y) = Tesselation.N.coords n
              in Draw.drawcircle (pixels, x, y, 2, TESSELATIONNODES)
              end

          fun drawline (a, b) =
              let val (x0, y0) = Tesselation.N.coords a
                  val (x1, y1) = Tesselation.N.coords b
              in
                  Draw.drawline (pixels, x0, y0, x1, y1, TESSELATIONLINES)
              end

          fun drawtriangle t =
              let val (a, b, c) = Tesselation.T.nodes t
              in
                  drawline (a, b);
                  drawline (b, c);
                  drawline (c, a)
              end
      in
          app drawtriangle triangles;
          app drawnode nodes
      end

  (* Always in game pixels. The event loop scales down x,y before
     calling any of these functions. *)
  val mousex = ref 0
  val mousey = ref 0
  val mousedown = ref false

  val MOUSECIRCLE = Draw.mixcolor (0wxFF, 0wxAA, 0wx33, 0wxFF)
  val CLOSESTCIRCLE = Draw.mixcolor (0wx44, 0wx44, 0wx44, 0wxFF)
  fun drawindicators () =
      let
          val (n1, n2, x, y) = Tesselation.closestedge tesselation (!mousex, !mousey)
      in
          Draw.drawcircle (pixels, !mousex, !mousey, 5, MOUSECIRCLE);
          Draw.drawcircle (pixels, x, y, 3, CLOSESTCIRCLE);
          ()
      end

  fun mousemotion (x, y) = ()
  fun leftmouse (x, y) = eprint (Int.toString x ^ "," ^ Int.toString y)
  fun leftmouseup (x, y) = ()

  val start = Time.now()

  fun keydown SDL.SDLK_ESCAPE = raise Quit
    | keydown _ = ()

  fun keyup _ = ()

  fun events () =
      case SDL.pollevent () of
          NONE => ()
        | SOME evt =>
           case evt of
               SDL.E_Quit => raise Quit
             | SDL.E_KeyDown { sym } => keydown sym
             | SDL.E_KeyUp { sym } => keyup sym
             | SDL.E_MouseMotion { state : SDL.mousestate,
                                   x : int, y : int, ... } =>
                   let
                       val x = x div PIXELSCALE
                       val y = y div PIXELSCALE
                   in
                       mousex := x;
                       mousey := y;
                       mousemotion (x, y)
                   end
             | SDL.E_MouseDown { button = 1, x, y, ... } =>
                   let
                       val x = x div PIXELSCALE
                       val y = y div PIXELSCALE
                   in
                       leftmouse (x, y)
                   end
             | SDL.E_MouseUp { button = 1, x, y, ... } =>
                   let
                       val x = x div PIXELSCALE
                       val y = y div PIXELSCALE
                   in
                       mousedown := false;
                       leftmouseup (x, y)
                   end
             | SDL.E_MouseDown { button = 4, ... } =>
                   let in
                       eprint "scroll up"
                   end

             | SDL.E_MouseDown { button = 5, ... } =>
                   let in
                       eprint "scroll down"
                   end
             | _ => ()

  fun loop () =
      let
          val () = events ()

          val () = Draw.randomize pixels
          val () = drawtesselation ()
          val () = drawindicators ()
          (* val () = Draw.scanline_postfilter pixels *)
          val () = fillscreen pixels
          val () = ctr := !ctr + 1
      in
          if !ctr mod 1000 = 0
          then
              let
                  val now = Time.now ()
                  val sec = Time.toSeconds (Time.-(now, start))
                  val fps = real (!ctr) / Real.fromLargeInt (sec)
              in
                  eprint (Int.toString (!ctr) ^ " (" ^
                          Real.fmt (StringCvt.FIX (SOME 2)) fps ^ ")")
              end
          else ();
          loop()
      end

  val () = loop ()

end