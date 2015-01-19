(*
 * Copyright (c) 2014, Hannes Mehnert
 * Copyright (c) 2014 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2014 David Kaloper
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * * Redistributions of source code must retain the above copyright notice, this
 *   list of conditions and the following disclaimer.
 *
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *)

open Lwt

type id = unit

type 'a io  = 'a Lwt.t
type buffer = Cstruct.t
type error  = [ `No_entropy_device of string ]

type handler = source:int -> buffer -> unit

type t = {
  (* Entropy data read from dom0 via a console *)
  console: Console_xen.t;
}

(* These are defined in xentropy/doc/protocol.md *)
let console_name = "org.openmirage.entropy.1"
let handshake_message =
  let string = "Hello, may I have some entropy?\r\n" in
  let buffer = Cstruct.create (String.length string) in
  Cstruct.blit_from_string string 0 buffer 0 (String.length string);
  buffer
let handshake_response = "You may treat everything following this message as entropy.\r\n"

let (>>|=) x f = x >>= function
| `Ok x -> f x
| `Eof ->
  print_endline "Received an EOF from the entropy console";
  return (`Error (`No_entropy_device console_name))
| `Error (`Invalid_console x) ->
  Printf.printf "Invalid_console %s\n%!" x;
  return (`Error (`No_entropy_device console_name))
| `Error _ ->
  Printf.printf "Unknown console device failure\n%!";
  return (`Error (`No_entropy_device console_name))

let connect () =
  Printf.printf "Entropy_xen: attempting to connect to Xen entropy source %s\n%!" console_name;
  Console_xen.connect console_name
  >>|= fun device ->
  Console_xen.write device handshake_message
  >>|= fun () ->
  Console_xen.read device
  >>|= fun buffer ->
  let string = Cstruct.sub buffer 0 (String.length handshake_response) |> Cstruct.to_string in
  if string <> handshake_response then begin
    Printf.printf "Entropy_xen: received [%s](%d bytes) instead of expected handshake message"
      (String.escaped string) (String.length string);
    return (`Error (`No_entropy_device console_name))
  end else begin
    print_endline "Entropy_xen: connected to Xen entropy source";
    return (`Ok { console = device })
  end

let disconnect _ = return_unit

let id _ = ()

let chunk = 16

let refeed t f =
  Console_xen.read t.console
  >>|= fun cs ->
  f ~source:(Cstruct.get_uint8 cs 0) (Cstruct.shift cs 1);
  return (`Ok ())

let handler t f =
  (* Read data from the console and advertise it.
     FIXME: we should do this more than once. How often? *)
  let (_: 'a Lwt.t) = refeed t f in
  return_unit

