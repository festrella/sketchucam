require 'sketchup.rb'
#require 'Phlatboyz/Constants.rb'
#see note at end of file
module PhlatScript

  class PhlatMill

    def initialize(output_file_name=nil, min_max_array=nil)
      #current_Feed_Rate = model.get_attribute Dict_name, $dict_Feed_Rate , nil
      #current_Plunge_Feed = model.get_attribute Dict_name, $dict_Plunge_Feed , nil
      @cz = 0.0
      @cx = 0.0
      @cy = 0.0
      @cs = 0.0
      @cc = ""
      @debug = false   # if true then a LOT of stuff will appear in the ruby console
      @debugramp = false
      puts "debug true in PhlatMill.rb\n" if (@debug || @debugramp)
      @quarters = $phoptions.quarter_arcs?  # use quarter circles in plunge bores?  defaults to true
#manual user options - if they find this they can use it (-:
      @quickpeck = $phoptions.quick_peck?   # if true will not retract to surface when peck drilling, withdraw only 0.5mm
      @canneddrill = false
      @depthfirst = $phoptions.depth_first? #depth first is old way, false gives diam first, spiralout()
      @fastapproach = true
      @laser = false  #frikken lasers!
#
      @max_x = 48.0
      @min_x = -48.0
      @max_y = 22.0
      @min_y = -22.0
      @max_z = 1.0
      @min_z = -1.0
      if(min_max_array != nil)
        @min_x = min_max_array[0]
        @max_x = min_max_array[1]
        @min_y = min_max_array[2]
        @max_y = min_max_array[3]
        @min_z = min_max_array[4]
        @max_z = min_max_array[5]
      end
      @no_move_count = 0
      @gforce = $phoptions.gforce?    # always output all Gcodes, for Marlin firmware, if true
      @spindle_speed = PhlatScript.spindleSpeed
      @retract_depth = PhlatScript.safeTravel.to_f
      @table_flag = false # true if tabletop is zZero
#      @mill_depth  = -0.35
      @speed_curr  = PhlatScript.feedRate
      @speed_plung = PhlatScript.plungeRate
      @material_w = PhlatScript.safeWidth
      @material_h = PhlatScript.safeHeight
      @material_thickness = PhlatScript.materialThickness
      @multidepth = PhlatScript.multipassDepth
      @bit_diameter = 0  #swarfer: need it often enough to be global

      @comment = PhlatScript.commentText
      @extr = "-"
      @cmd_linear = "G01" # Linear interpolation
      @cmd_rapid = "G0" # Rapid positioning - do not change this to G00 as G00 is used elsewhere for forcing mode change
      @cmd_arc = "G02" # coordinated helical motion about Z axis
      @cmd_arc_rev = "G03" # counterclockwise helical motion about Z axis
      @output_file_name = output_file_name
      @mill_out_file = nil

      @Limit_up_feed = false #swarfer: set this to true to use @speed_plung for Z up moves
      @cw =  PhlatScript.usePlungeCW?           #swarfer: spiral cut direction
      
      @tooshorttoramp = 0.02     #length of an edge that is too short to bother ramping
    end

   def set_retract_depth(newdepth, tableflag)
      @retract_depth = newdepth
      @table_flag = tableflag
   end

    def set_bit_diam(diameter)
      #@curr_bit.diam = diameter
      @bit_diameter = diameter
      @tooshorttoramp = diameter / 2   # do not ramp edges that are less than a bit radius long - also affect optimizer
    end
    
    def tooshorttoramp
       @tooshorttoramp
    end
    
    #sketchup compares to 0.001" but that is too coarse, so we do it ourselves to 10 times that  (1.4a)
    def notequal(a,b)
       return (a-b).abs > 0.0001
    end

    def cncPrint(*args)
      if(@mill_out_file)
        args.each {|string| 
           string = string.to_s.sub(/G0 /,'G00 ')  #changing G0 to G00 everywhere else is tricky, just do it here
           @mill_out_file.print(string)
           }
      else
        args.each {|string| print string}
        #print arg
      end
    end
   
   #returns array of strings of length size or less
   def chunk(string, size)
      string.scan(/.{1,#{size}}/)
   end 
    
    #print a commment using current comment options
   def cncPrintC(string)
      if ($phoptions.usecomments?)    # only output comments if usecomments is true
         string = string.strip.gsub(/\n/,"")
         string = string.gsub(/\(|\)/,"")
         if (string.length > 48)
            chunks = chunk(string,45)
            chunks.each { |bit|
               bb = PhlatScript.gcomment(bit)
               cncPrint(bb + "\n")
               }
         else
            string = PhlatScript.gcomment(string)
            cncPrint(string + "\n")
         end
      end
   end

    def format_measure(axis, measure)
      #UI.messagebox("in #{measure}")
      m2 = @is_metric ? measure.to_mm : measure.to_inch
      #UI.messagebox(sprintf("  #{axis}%-10.*f", @precision, m2))
      #UI.messagebox("out mm: #{measure.to_mm} inch: #{measure.to_inch}")
      axis.upcase!
      out = sprintf(" #{axis.lstrip}%-5.*f", @precision, m2)
      #strip trailing 0's to shorten line for GRBL
      if (@precision > 3)
         while out =~ /00$/
            out = out.gsub(/00$/,'0')
         end
         if (out =~ /\.0/) == nil
            if (out =~ /0$/) != nil
               out = out.gsub(/0$/,'')
            end
         end
      end
      return out
    end

    def format_feed(f)
      feed = @is_metric ? f.to_mm : f.to_inch
      sprintf(" F%-4d", feed.to_i)
    end

    def job_start(optim, extra=@extr)
      if(@output_file_name)
        done = false
        while !done do
          begin
            @mill_out_file = File.new(@output_file_name, "w")
            done = true
          rescue
            button_pressed = UI.messagebox "Exception in PhlatMill.job_start "+$!, 5 #, RETRYCANCEL , "title"
            done = (button_pressed != 4) # 4 = RETRY ; 2 = CANCEL
            # TODO still need to handle the CANCEL case ie. return success or failure
          end
        end
      end
#      @bit_diameter = Sketchup.active_model.get_attribute Dict_name, Dict_bit_diameter, Default_bit_diameter
      @bit_diameter = PhlatScript.bitDiameter
      @tooshorttoramp = @bit_diameter / 2

      cncPrint("%\n")
#do a little jig to prevent the code highlighter getting confused by the bracket constructs      
      vs1 = PhlatScript.getString("PhlatboyzGcodeTrailer")
      vs2 = $PhlatScriptExtension.version
      verstr = "#{vs1%vs2}" + "\n"
      cncPrintC(verstr)
      if PhlatScript.sketchup_file
         fn = PhlatScript.sketchup_file.gsub(/\(|\)/,"-") # remove existing brackets, confuses CNC controllers to have embedded brackets
      else
         fn = "nonam"         
      end
      cncPrintC("File: #{fn}") if PhlatScript.sketchup_file
      cncPrintC("Bit diameter: #{Sketchup.format_length(@bit_diameter)}")
      cncPrintC("Feed rate: #{Sketchup.format_length(@speed_curr)}/min")
      if (@speed_curr != @speed_plung)
         cncPrintC("Plunge Feed rate: #{Sketchup.format_length(@speed_plung)}/min")
      end
      cncPrintC("Material Thickness: #{Sketchup.format_length(@material_thickness)}")
      cncPrintC("Material length: #{Sketchup.format_length(@material_h)} X width: #{Sketchup.format_length(@material_w)}")
      cncPrintC("Overhead Gantry: #{PhlatScript.useOverheadGantry?}")
      if (@Limit_up_feed)
        cncPrintC("Retract feed LIMITED to plunge feed rate")
      end
      if (PhlatScript.useMultipass?)
        cncPrintC("Multipass enabled, Depth = #{Sketchup.format_length(@multidepth)}")
      end
      if (PhlatScript.mustramp?)
         if (PhlatScript.rampangle == 0)
            cncPrintC("RAMPING with no angle limit")
         else
            cncPrintC("RAMPING at #{PhlatScript.rampangle} degrees")
         end
      end

      if (@depthfirst)
         cncPrintC("Plunge Depth first")
      else
         cncPrintC("Plunge Diam First")
      end
      
      if ($phoptions.toolnum > -1)
         cncPrintC("Using plain toolchange")
      end
      if $phoptions.toolfile != 'no'
         cncPrintC("Using toolchange file #{File.basename($phoptions.toolfile)}")
      end
      
      if (optim)    # swarfer - display optimize status as part of header
        cncPrintC("Optimization is ON")
      else
        cncPrintC("Optimization is OFF")
      end
      if (@laser)    # swarfer - display laser mode status as part of header
        cncPrintC("LASER is ON")
      end
      
      if (extra != "-")
         #puts extra
         extra.split(/\n/).each {|bit|  cncPrintC(bit) }
      end

      cncPrintC("www.PhlatBoyz.com")
      PhlatScript.checkParens(@comment, "Comment")
      #puts @comment
      @comment.split(/\$\//).each{|line| cncPrintC(line)} if !@comment.empty?

      #adapted from swarfer's metric code
      #metric by SWARFER - this does the basic setting up from the drawing units
      if PhlatScript.isMetric
        unit_cmd, @precision, @is_metric = ["G21", 3, true]
      else
        unit_cmd, @precision, @is_metric = ["G20", 4, false]
      end

      stop_code = $phoptions.use_exact_path? ? "G61" : "" # G61 - Exact Path Mode
      cncPrint("G90 #{unit_cmd} G49 #{stop_code} G17\n") # G90 - Absolute programming (type B and C systems)
      
#tool change      
      if ($phoptions.toolnum > -1)
         tool = "T#{$phoptions.toolnum} M06"
         if $phoptions.useg43?
            tool += " G43"
            if $phoptions.useH?
               tool += " H#{$phoptions.toolh}"     if ($phoptions.toolh > -1)
            end
         end
         tool += "\n"
         cncPrint(tool)
      else
         if $phoptions.toolfile != 'no'
            lines = IO.readlines($phoptions.toolfile)
            if lines
               tool = ''
               lines.each { |line|
                  if !line.match(/%s/)
                     tool += line
                  else  # stick in the tooloffset in the %s place
                     line = sprintf(line,format_measure('',$phoptions.tooloffset).strip )
                     tool += line
                  end
                  }
               cncPrint(tool)   
            end
         end
      end
      
      #output A or B axis rotation if selected
      if ($phoptions.useA?)
         cncPrint("G00 A", $phoptions.posA.to_s , "\n")
      end
      if ($phoptions.useB?)
         cncPrint("G00 B", $phoptions.posB.to_s , "\n")
      end
      if ($phoptions.useC?)
         cncPrint("G00 C", $phoptions.posC.to_s , "\n")
      end
      if (@laser == false)
         cncPrint("M3 S", @spindle_speed, "\n") # M3 - Spindle on (CW rotation)   S spindle speed
      end
    end

   def job_finish
      if ($phoptions.useA? || $phoptions.useB? || $phoptions.useC?)
         cncPrint("G00")
         if ($phoptions.useA?)
            cncPrint(" A0.0")
         end
         if ($phoptions.useB?)
            cncPrint(" B0.0")
         end
         if ($phoptions.useC?)
            cncPrint(" C0.0")
         end
         cncPrint("\n")
      end
         
      cncPrint("M05\n") # M05 - Spindle off
      cncPrint("M30\n") # M30 - End of program/rewind tape
      cncPrint("%\n")
      if(@mill_out_file)
        begin
          @mill_out_file.close()
          @mill_out_file = nil
          UI.messagebox("Output file stored: "+@output_file_name)
        rescue
          UI.messagebox "Exception in PhlatMill.job_finish "+$!
        end
      else
        UI.messagebox("Failed to store output file. (File may be opened by another application.)")
      end
    end

   def move(xo, yo=@cy, zo=@cz, so=@speed_curr, cmd=@cmd_linear)
     #cncPrintC("(move ", sprintf("%10.6f",xo), ", ", sprintf("%10.6f",yo), ", ", sprintf("%10.6f",zo),", ", sprintf("feed %10.6f",so), ", cmd=", cmd,")\n")
     #puts "(move ", sprintf("%10.6f",xo), ", ", sprintf("%10.6f",yo), ", ", sprintf("%10.6f",zo),", ", sprintf("feed %10.6f",so), ", cmd=", cmd,")\n"
      if cmd != @cmd_rapid
         if @retract_depth == zo
            cmd=@cmd_rapid
            so=0
            @cs=0
         else
            cmd=@cmd_linear
         end
      end

      #print "( move xo=", xo, " yo=",yo,  " zo=", zo,  " so=", so,")\n"
      if (xo == @cx) && (yo == @cy) && (zo == @cz)
         #print "(move - already positioned)\n"
         @no_move_count += 1
      else
         if (xo > @max_x)
            #puts "xo big"
            cncPrintC("move x=" + sprintf("%10.6f",xo) + " GT max of " + @max_x.to_s + "\n")
            xo = @max_x
         elsif (xo < @min_x)
            #puts "xo small"
            cncPrintC("move x="+ sprintf("%10.6f",xo)+ " LT min of "+ @min_x.to_s+ "\n")
            xo = @min_x
         end

         if (yo > @max_y)
            #puts "yo big"
            cncPrintC("move y="+ sprintf("%10.6f",yo)+ " GT max of "+ @max_y.to_s+ "\n")
            yo = @max_y
         elsif (yo < @min_y)
            #puts "yo small"
            cncPrintC("move y="+ sprintf("%10.6f",yo)+ " LT min of "+ @min_y.to_s+ "\n")
            yo = @min_y
         end

         if (zo > @max_z)
            cncPrintC("(move z="+ sprintf("%10.6f",zo)+ " GT max of "+ @max_z.to_s+ ")\n")
            zo = @max_z
         elsif (zo < @min_z)
            cncPrintC("(move ="+ sprintf("%8.3f",zo)+ " LT min of "+ @min_z.to_s+ ")\n")
            zo = @min_z
         end
         command_out = ""
         command_out += cmd if ((cmd != @cc) || @gforce)
         hasz = hasx = hasy = false
         if ( notequal(xo, @cx) )
            command_out += (format_measure('X', xo))
            hasx = true
         end
         if ( notequal(yo, @cy) )
            command_out += (format_measure('Y', yo))
            hasy = true
         end
         if ( notequal(zo, @cz) )
            hasz = true
            command_out += (format_measure('Z', zo))
         end

         if (!hasx && !hasy && hasz) # if only have a Z motion
            if (zo < @cz) || (@Limit_up_feed)  # if going down, or if overridden
               so = PhlatScript.plungeRate
            #            cncPrintC("(move only Z, force plungerate)\n")
            end
         end
         #          cncPrintC("(   #{hasx} #{hasy} #{hasz})\n")
         command_out += (format_feed(so)) if (so != @cs)
         command_out += "\n"
         cncPrint(command_out)
         @cx = xo
         @cy = yo
         @cz = zo
         @cs = so
         @cc = cmd
      end
   end

   def retract(zo=@retract_depth, cmd=@cmd_rapid)
      #      cncPrintC("(retract ", sprintf("%10.6f",zo), ", cmd=", cmd,")\n")
      #      if (zo == nil)
      #        zo = @retract_depth
      #      end
      if (@cz == zo)
         @no_move_count += 1
      else
         if (zo > @max_z)
            msg = "(RETRACT limiting Z to @max_z)\n"
            cncPrintC(msg)
            puts msg
            zo = @max_z
         elsif (zo < @min_z)
            msg = "(RETRACT limiting Z to @min_z)\n"
            cncPrintC(msg)
            puts msg
            zo = @min_z
         end
         command_out = ""
         if (@laser)
            command_out += "M05"
         else
            if (@Limit_up_feed) && (cmd=="G0") && (zo > 0) && (@cz < 0)
               cncPrintC("(RETRACT G1 to material thickness at plunge rate)\n")
               command_out += 'G01' + (format_measure('Z', 0))
               command_out += (format_feed(@speed_plung))
               command_out += "\n"
               $cs = @speed_plung
               #          G00 to zo
               command_out += "G00" + (format_measure('Z', zo))
            else
               #          cncPrintC("(RETRACT normal #{@cz} to #{zo} )\n")
               command_out += cmd    if ((cmd != @cc) || @gforce)
               command_out += (format_measure('Z', zo))
            end
         end
         command_out += "\n"
         cncPrint(command_out)
         @cz = zo
         @cc = cmd
      end
   end

   # zo is Z level to go to
   # so is feed speed to use
   # cmd = default cmd, normally G01
   # fast = use fastappraoch , set to false to force it off
   def plung(zo, so=@speed_plung, cmd=@cmd_linear, fast=true)
      #      cncPrintC("(plung ", sprintf("%10.6f",zo), ", so=", so, " cmd=", cmd,")\n")
      if (zo == @cz)
         @no_move_count += 1
      else
         if (zo > @max_z)
            msg = "(PLUNGE limiting Z to max_z @max_z)\n"
            cncPrintC(msg)
            puts msg
            zo = @max_z
         elsif (zo < @min_z)
            msg = "(PLUNGE limiting Z to min_z @min_z)\n"
            cncPrintC(msg)
            puts msg
            zo = @min_z
         end
         command_out = ""
         if (@laser)
            command_out += "M03"
         else
            # if above material, G00 to near surface, fastapproach
            if (fast && @fastapproach)
               if (@cz == @retract_depth) && (zo < @cz)
                  offset = @is_metric ? 0.5.mm : 0.02.inch
                  flag = false
                  if (@table_flag)
                     if ((@material_thickness + offset) < @retract_depth)
                        @cz = @material_thickness + offset
                        flag = true
                     end
                  else
                     if offset < @retract_depth
                        @cz = 0.0 + offset   
                        flag = true
                     end
                  end
                  if (flag)
                     command_out += "G00" + format_measure('Z',@cz) +"\n"
                     @cc = @cmd_rapid
                  end
               end
            end
            command_out += cmd if ((cmd != @cc) || @gforce)
            command_out += (format_measure('Z', zo))
            so = @speed_plung  # force using plunge rate for vertical moves
            #        sox = @is_metric ? so.to_mm : so.to_inch
            #        cncPrintC("(plunge rate #{sox})\n")
            command_out += (format_feed(so)) if (so != @cs)
         end
         command_out += "\n"
         cncPrint(command_out)
         @cz = zo
         @cs = so
         @cc = cmd
      end
   end

# convert degrees to radians   
   def torad(deg)
       deg * Math::PI / 180
   end     

   def todeg(rad)
      rad * 180 / Math::PI 
   end
   
   def ramp(limitangle, op, zo, so=@speed_plung, cmd=@cmd_linear)   
      if limitangle > 0
         ramplimit(limitangle, op, zo, so, cmd)
      else
         rampnolimit(op, zo, so, cmd)
      end
   end

## this ramp is limited to limitangle, so it will do multiple ramps to satisfy this angle   
   def ramplimit(limitangle, op, zo, so=@speed_plung, cmd=@cmd_linear)
      cncPrintC("(ramp limit #{limitangle}deg zo="+ sprintf("%10.6f",zo)+ ", so="+ so.to_s+ " cmd="+ cmd+"  op="+op.to_s.delete('()')+")\n") if (@debugramp) 
      if (zo == @cz)
         @no_move_count += 1
      else
         # we are at a point @cx,@cy,@cz and need to ramp to op.x,op.y, limiting angle to rampangle ending at @cx,@cy,zo
         if (zo > @max_z)
            cncPrintC("(RAMP limiting Z to max_z #{@max_z})\n")
            zo = @max_z
         elsif (zo < @min_z)
            cncPrintC("(RAMP limiting Z to min_z #{@min_z})\n")
            zo = @min_z
         end
      
         command_out = ""
         # if above material, G00 to near surface to save time
         if (@cz == @retract_depth)
            if (@table_flag)
               @cz = @material_thickness + 0.2.mm
            else
               @cz = 0.0 + 0.2.mm
            end
            command_out += "G00" + format_measure('Z',@cz) +"\n"
            @cc = @cmd_rapid
         end
         
         # find halfway point
         # is the angle exceeded?
         point1 = Geom::Point3d.new(@cx,@cy,0)  # current point
         point2 = Geom::Point3d.new(op.x,op.y,0) # the other point
         distance = point1.distance(point2)   # this is 'adjacent' edge in the triangle, bz is opposite
         
         if (distance < @tooshorttoramp)  # dont need to ramp really since not going anywhere far, just plunge
            puts "distance=#{distance.to_mm} < #{@tooshorttoramp.to_mm} so just plunging"  if(@debugramp)
            plung(zo, so, @cmd_linear)
            cncPrintC("ramplimit end, translated to plunge\n")
            @cz = zo
            @cs = so
            @cc = @cmd_linear
            return
         end
         
         bz = ((@cz-zo)/2).abs   #half distance from @cz to zo, not height to cut to
         
         anglerad = Math::atan(bz/distance)
         angledeg = todeg(anglerad)
         
         if (angledeg > limitangle)  # then need to calculate a new bz value
            puts "limit exceeded  #{angledeg} > #{limitangle}  old bz=#{bz}" if(@debugramp)
            bz = distance * Math::tan( torad(limitangle) )
            if (bz == 0)
               puts "distance=#{distance} bz=#{bz}"
               passes =4
            else
               passes = ((zo-@cz)/bz).abs
            end   
            puts "   new bz=#{bz.to_mm} passes #{passes}"                  if(@debugramp) # should always be even number of passes?
            passes = passes.floor
            if passes.modulo(2).zero?
               passes += 2
            else
               passes += 1
            end
            if (passes > 100)
               cncPrintC("clamping ramp passes to 100, segment very short")
               puts "clamping ramp passes to 100"
               passes = 100
            end
            bz = (zo-@cz).abs / passes
            puts "   rounded new bz=#{bz.to_mm} passes #{passes}"        if(@debugramp)  # now an even number
         else
            puts "bz is half distance"    if(@debugramp)
            #bz = (zo-@cz)/2 + @cz
         end  
         puts "bz=#{bz.to_mm}" if(@debugramp)

         so = @speed_plung  # force using plunge rate for ramp moves
         
         curdepth = @cz
         cnt = 0
         errmsg = ''
         while ( (curdepth - zo).abs > 0.0001) do
            cnt += 1
            if cnt > 1000
               puts "high count break #{curdepth.to_mm}  #{zo.to_mm}" 
               command_out += "ramp loop high count break, do not cut this code\n"
               errmsg = "ramp loop high count break, do not cut this code"
               break
            end
            puts "curdepth #{curdepth.to_mm}"            if(@debugramp)
            # cut to Xop.x Yop.y Z (zo-@cz)/2 + @cz
            command_out += cmd      if ((cmd != @cc) || @gforce)
            @cc = cmd
            command_out += format_measure('x',op.x)
            command_out += format_measure('y',op.y)
# for the last pass, make sure we do equal legs - this is mostly circumvented by the passes adjustment
            if (zo-curdepth).abs < (bz*2)
               puts "last pass smaller bz"               if(@debugramp)
               bz = (zo-curdepth).abs / 2
            end
            
            curdepth -= bz
            if (curdepth < zo)
               curdepth = zo
            end   
            command_out += format_measure('z',curdepth)
            command_out += (format_feed(so)) if (so != @cs)
            @cs = so
            command_out += "\n";

            # cut to @cx,@cy, curdepth
            curdepth -= bz
            if (curdepth < zo)
               curdepth = zo
            end   
            command_out += cmd      if ((cmd != @cc) || @gforce)
            command_out += format_measure('X',@cx)
            command_out += format_measure('y',@cy)
            command_out += format_measure('z',curdepth)
            command_out += "\n"
         end  # while
         if (errmsg != '')
            UI.messagebox(errmsg)
         end
         
         cncPrint(command_out)
         cncPrintC("(ramplimit end)\n")             if(@debugramp)
         @cz = zo
         @cs = so
         @cc = cmd
      end
   end

## this ramps down to half the depth at otherpoint, and back to cut_depth at start point
## this may end up being quite a steep ramp if the distance is short
   def rampnolimit(op, zo, so=@speed_plung, cmd=@cmd_linear)
      cncPrintC("(ramp "+ sprintf("%10.6f",zo)+ ", so="+ so.to_mm.to_s+ " cmd="+ cmd+"  op="+op.to_s.delete('()')+")\n") if (@debugramp) 
      if (zo == @cz)
         @no_move_count += 1
         cncPrintC("rampnolimit no move")
      else
         # we are at a point @cx,@cy and need to ramp to op.x,op.y,zo/2 then back to @cx,@cy,zo
         if (zo > @max_z)
            cncPrintC("(RAMP limiting Z to max_z @max_z)\n")
            zo = @max_z
         elsif (zo < @min_z)
            cncPrintC("(RAMP limiting Z to min_z @min_z)\n")
            zo = @min_z
         end
         command_out = ""
         # if above material, G00 to surface
         if (@cz == @retract_depth)
            if (@table_flag)
               @cz = @material_thickness + 0.2.mm
            else
               @cz = 0.0 + 0.2.mm
            end
            command_out += "G00" + format_measure('Z',@cz) +"\n"
            @cc = @cmd_rapid
         end
         
# check the distance         
         point1 = Geom::Point3d.new(@cx,@cy,0)  # current point
         point2 = Geom::Point3d.new(op.x,op.y,0) # the other point
         distance = point1.distance(point2)   # this is 'adjacent' edge in the triangle, bz is opposite
         if (distance < @tooshorttoramp)  # dont need to ramp really since not going anywhere far, just plunge
            puts "distance=#{distance.to_mm} so just plunging"  if(@debugramp)
            plung(zo, so, @cmd_linear)
            @cz = zo
            @cs = so
            @cc = @cmd_linear
            cncPrintC("rampnolimit end, plunging\n")
            return
         end
         
         # cut to Xop.x Yop.y Z (zo-@cz)/2 + @cz
         command_out += cmd   if ((cmd != @cc) || @gforce)
         @cc = cmd
         command_out += format_measure('x',op.x)
         command_out += format_measure('y',op.y)
         bz = (zo-@cz)/2 + @cz
         command_out += format_measure('z',bz)
         command_out += (format_feed(so)) if (so != @cs)
         command_out += "\n";
         # cut to @cx,@cy,zo
         command_out += cmd   if ((cmd != @cc) || @gforce)
         command_out += format_measure('X',@cx)
         command_out += format_measure('y',@cy)
         command_out += format_measure('z',zo)
         
         command_out += "\n"
         cncPrint(command_out)
         @cz = zo
         @cs = so
         @cc = cmd
      end
   end

#If you mean the angle that P1 is the vertex of then this should work:
#    arcos((P12^2 + P13^2 - P23^2) / (2 * P12 * P13))
#where P12 is the length of the segment from P1 to P2, calculated by
#    sqrt((P1x - P2x)^2 + (P1y - P2y)^2)

# cunning bit of code found online, find the angle between 3 points, in radians
#just give it the three points as arrays
# p1 is the center point; result is in radians
   def angle_between_points( p0, p1, p2 )
     a = (p1[0]-p0[0])**2 + (p1[1]-p0[1])**2
     b = (p1[0]-p2[0])**2 + (p1[1]-p2[1])**2
     c = (p2[0]-p0[0])**2 + (p2[1]-p0[1])**2
     Math.acos( (a+b-c) / Math.sqrt(4*a*b) ) 
   end
   
## this arc ramp is limited to limitangle, so it will do multiple ramps to satisfy this angle   
## not going to write an unlimited version, always limited to at most 45 degrees
## though some of these arguments are defaulted, they must always all be given by the caller
   def ramplimitArc(limitangle, op, rad, cent, zo, so=@speed_plung, cmd=@cmd_linear)
      if (limitangle == 0)
         limitangle = 45   # always limit to something
      end
      cncPrintC("ramplimitArc")  if (@debugramparc)
      cncPrintC("(ramp arc limit #{limitangle}deg zo="+ sprintf("%10.6f",zo)+ ", so="+ so.to_s+ " cmd="+ cmd+"  op="+op.to_s.delete('()')+")\n") if (@debugramparc) 
      if (zo == @cz)
         @no_move_count += 1
      else
         # we are at a point @cx,@cy,@cz and need to arcramp to op.x,op.y, limiting angle to rampangle ending at @cx,@cy,zo
         # cmd will be the initial direction, need to reverse for the backtrack
         if (zo > @max_z)
            cncPrintC("(RAMParc limiting Z to max_z @max_z)\n")
            zo = @max_z
         elsif (zo < @min_z)
            cncPrintC("(RAMParc limiting Z to min_z @min_z)\n")
            zo = @min_z
         end
      
         command_out = ""
         # if above material, G00 to near surface to save time
         if (@cz == @retract_depth)
            if (@table_flag)
               @cz = @material_thickness + 0.2.mm
            else
               @cz = 0.0 + 0.2.mm
            end
            command_out += "G00" + format_measure('Z',@cz) +"\n"
            cncPrint(command_out)
            @cc = @cmd_rapid
         end
         
	
         angle = angle_between_points([@cx,@cy], [cent.x,cent.y] , [op.x,op.y])
         arclength = angle * rad
         puts "angle #{angle} arclength #{arclength.to_mm}"    if (@debugramp)
#with the angle we can find the arc length
#angle*radius   (radians)
         
         if (cmd.include?('3'))  # find the 'other' command for the return stroke
            ocmd = 'G02'
         else
            ocmd = 'G03'
         end
         # find halfway point
         # is the angle exceeded?
#         point1 = Geom::Point3d.new(@cx,@cy,0)  # current point
#         point2 = Geom::Point3d.new(op.x,op.y,0) # the other point
#         distance = point1.distance(point2)   # this is 'adjacent' edge in the triangle, bz is opposite
         distance =  arclength
         if (distance < @tooshorttoramp)  # dont need to ramp really since not going anywhere, just plunge
            puts "arcramp distance=#{distance.to_mm} so just plunging"  if(@debugramp)
            plung(zo, so, @cmd_linear)
            cncPrintC("ramplimitarc end, translated to plunge\n")
            return
         end
         
         bz = ((@cz-zo)/2).abs   #half distance from @cz to zo, not height to cut to
         
         anglerad = Math::atan(bz/distance)
         angledeg = todeg(anglerad)
         
         if (angledeg > limitangle)  # then need to calculate a new bz value
            puts "arcramp limit exceeded  #{angledeg} > #{limitangle}  old bz=#{bz}" if(@debugramp)
            bz = distance * Math::tan( torad(limitangle) )
            if (bz == 0)
               puts "distance=#{distance} bz=#{bz}"                        if (@debugramp)
               passes = 4
            else
               passes = ((zo-@cz)/bz).abs
            end   
            puts "   new bz=#{bz.to_mm} passes #{passes}"                  if(@debugramp) # should always be even number of passes?
            passes = passes.floor
            if passes.modulo(2).zero?
               passes += 2
            else
               passes += 1
            end
            bz = (zo-@cz).abs / passes
            puts "   rounded new bz=#{bz.to_mm} passes #{passes}"          if(@debugramp) # now an even number
         else
            puts "bz is half distance"          if(@debugramp)
            #bz = (zo-@cz)/2 + @cz
         end
         puts "bz=#{bz.to_mm}" if(@debugramp)

         so = @speed_plung  # force using plunge rate for ramp moves
         
         curdepth = @cz
         cnt = 0
         command_out = ''
         @precision += 1
         while ( (curdepth - zo).abs > 0.0001) do
            command_out += cmd
            cnt += 1
            if cnt > 1000
               puts "high count break" 
               command_out += "ramp arc loop high count break, do not cut this code\n"
               break
            end
            puts "   curdepth #{curdepth.to_mm}"            if(@debugramp)
            # cut to Xop.x Yop.y Z (zo-@cz)/2 + @cz
            command_out += format_measure('x',op.x)
            command_out += format_measure('y',op.y)
# for the last pass, make sure we do equal legs - this is mostly circumvented by the passes adjustment
            if (zo-curdepth).abs < (bz*2)
               puts "   last pass smaller bz"               if(@debugramp)
               bz = (zo-curdepth).abs / 2
            end
            
            curdepth -= bz
            if (curdepth < zo)
               curdepth = zo
            end   
            command_out += format_measure('z',curdepth)
            command_out += format_measure('r',rad)
            command_out += (format_feed(so)) if (so != @cs)
            @cs = so
            command_out += "\n";

            # cut to @cx,@cy, curdepth
            curdepth -= bz
            if (curdepth < zo)
               curdepth = zo
            end   
            command_out += ocmd
            command_out += format_measure('X',@cx)
            command_out += format_measure('Y',@cy)
            command_out += format_measure('Z',curdepth)
            command_out += format_measure('R',rad)
            command_out += "\n"
         end  # while
         @precision -= 1
         cncPrint(command_out)
         cncPrintC("(ramplimitarc end)\n")             if(@debugramp)
         @cz = zo
         @cs = so
         @cc = ocmd #ocmd is the last command output
      end
   end
   

# generate code for a spiral bore and return the command string
# if ramping is on, lead angle will be limited to rampangle
 #sh = safeheight, where @cz is now, usually
   def SpiralAt(xo,yo,zstart,zend,yoff)
      @precision += 1
      cwstr = @cw ? 'CW' : 'CCW';
      cmd =   @cw ? 'G02': 'G03';
      command_out = ""
      command_out += "   (SPIRAL #{xo.to_mm},#{yo.to_mm},#{(zstart-zend).to_mm},#{yoff.to_mm},#{cwstr})\n" if @debugramp
      command_out += "G00" + format_measure("X",xo) 
      command_out +=         format_measure("Y",yo-yoff) + "\n"
      if (@cz != (zstart + 0.5.mm))
         command_out += "G00" if (@gforce)
         command_out += "   " if (!@gforce)
         command_out += format_measure("Z",zstart+0.5.mm) + "\n"  # rapid to near surface if not already there
      end
      
      command_out += "G01" + format_measure("Z",zstart)        # feed to surface
      feed = @speed_plung
      command_out += format_feed(feed)   #always feed at plunge rate
      command_out += "\n"
      #if ramping with limit use plunge feed rate
      @cs = (PhlatScript.mustramp? && (PhlatScript.rampangle > 0)) ? @speed_plung : @speed_curr

      #// now output spiral cut
      #//G02 X10 Y18.5 Z-3 I0 J1.5 F100
      if (PhlatScript.mustramp? && (PhlatScript.rampangle > 0))
         #calculate step for this diameter
         #calculate lead for this angle spiral
         circ = Math::PI * yoff.abs * 2   # yoff is radius
         step = -Math::tan(torad(PhlatScript.rampangle)) * circ
         puts "(SpiralAt z step = #{step.to_mm} for ramp circ #{circ.to_mm}"         if (@debugramp)
         # now limit it to multipass depth or half bitdiam because it can get pretty steep for small diameters
         if PhlatScript.useMultipass?
            if step.abs > PhlatScript.multipassDepth
               step = -PhlatScript.multipassDepth
               step = StepFromMpass(zstart,zend,step)
               puts " step #{step.to_mm} limited to multipass"       if (@debugramp)
            end
         else
            if step.abs > (@bit_diameter/2)
#               s = ((zstart-zend) / (@bit_diameter/2)).ceil #;  // each spiral Z feed will be bit diameter/2 or slightly less
#               step = -(zstart-zend) / s
               step = StepFromBit(zstart,zend)
               puts " step #{step.to_mm} limited to fuzzybitdiam/2"       if (@debugramp)
            end
         end
      else
         if PhlatScript.useMultipass?
            step = -PhlatScript.multipassDepth
            step = StepFromMpass(zstart,zend,step)
         else
#            s = ((zstart-zend) / (@bit_diameter/2)).ceil #;  // each spiral Z feed will be bit diameter/2 or slightly less
#            step = -(zstart-zend) / s     # ensures every step down is the same size
            step = StepFromBit(zstart,zend)
         end
      end
      mpass = -step
      d = zstart-zend
      puts("Spiralat: step #{step.to_mm} zstart #{zstart.to_mm} zend #{zend.to_mm}  depth #{d.to_mm}" )   if @debug
      command_out += "   (Z step #{step.to_mm})\n"          if @debug
      now = zstart
      while now > zend do
         now += step
         if (now < zend)
            now = zend
         else
            df = zend - now # must prevent this missing the last spiral on small mpass depths, ie when mpass < bit/8
            if (df.abs < 0.001) #make sure we do not repeat the last pass
               now = zend
            else
               if ( df.abs < (mpass / 4) )
                  if (df < 0) 
                     command_out += "   (SpiralAt: forced depth as very close now #{now.to_mm} zend #{zend.to_mm}" if @debug
                     command_out += format_measure("df",df) + ")\n"                if @debug
                     now = zend
                  end
               end
            end
         end
         command_out += "#{cmd} "
         command_out += format_measure("X",xo)
         command_out += format_measure("Y",yo-yoff)
         command_out += format_measure("Z",now)
         command_out += " I0"
         command_out += format_measure("J",yoff)
         if (feed != @cs)
            command_out += format_feed(@cs)  
            feed = @cs
         end         
         command_out += "\n"
      end # while
    # now the bottom needs to be flat at $depth
      command_out += "#{cmd} "
      command_out += format_measure("X",xo)
      command_out += format_measure("Y",yo-yoff)
      command_out += " I0.0"
      command_out += format_measure("J",yoff)
      command_out += "\n";
      command_out += "   (SPIRAL END)\n" if @debug
      @precision -= 1
      return command_out
    end # SpiralAt
    
   def StepFromBit(zstart, zend)
      s = ((zstart-zend) / (@bit_diameter/2)).ceil #;  // each spiral Z feed will be bit diameter/2 or slightly less
      step = -(zstart-zend) / s
   end
   
   def StepFromMpass(zstart,zend,step)
      c = (zstart - zend) / PhlatScript.multipassDepth  # how many passes will it take
      if ( ((c % 1) > 0.01) && ((c % 1) < 0.5))  # if a partial pass, and less than 50% of a pass, then scale step smaller
         c = c.ceil
         step = -(zstart - zend) / c
      end
      return step
   end

# generate code for a spiral bore and return the command string, using quadrants
# if ramping is on, lead angle will be limited to rampangle
   def SpiralAtQ(xo,yo,zstart,zend,yoff)
#   @debugramp = true
      @precision += 1
      cwstr = @cw ? 'CW' : 'CCW';
      cmd =   @cw ? 'G02': 'G03';
      command_out = ""
      command_out += "   (SPIRALQ #{sprintf('X%0.2f',xo.to_mm)},#{sprintf('Y%0.2f',yo.to_mm)},#{sprintf('depth %0.2f',(zstart-zend).to_mm)},#{sprintf('yoff %0.2f',yoff.to_mm)},#{cwstr})\n" if @debug
      #have to do X again to have the extra precision we are now using
      command_out += "G00" + format_measure("X",xo) 
      command_out +=         format_measure("Y",yo-yoff) + "\n"    
      if (@cz != (zstart + 0.5.mm))
      puts "cz #{@cz} zstart #{zstart}"
         command_out += "G00" if (@gforce)
         command_out += "   " if (!@gforce)
         command_out += format_measure("Z",zstart+ 0.5.mm) + "\n"   # rapid to near surface
      end
      command_out += "G01" + format_measure("Z",zstart) # feed to surface
      feed = @speed_plung
      command_out += format_feed(feed)   #always feed at plunge rate
      command_out += "\n"
      #if ramping with limit use plunge feed rate
      @cs = (PhlatScript.mustramp? && (PhlatScript.rampangle > 0)) ? @speed_plung : @speed_curr

      #// now output spiral cut
      #//G02 X10 Y18.5 Z-3 I0 J1.5 F100
      if (PhlatScript.mustramp? && (PhlatScript.rampangle > 0))
         #calculate step for this diameter
         #calculate lead for this angle spiral
         circ = Math::PI * yoff.abs * 2   # yoff is radius
         step = -Math::tan(torad(PhlatScript.rampangle)) * circ
         puts "(SpiralAtQ z step = #{step.to_mm} for ramp circ #{circ.to_mm}"         if (@debugramp)
         # now limit it to multipass depth or half bitdiam because it can get pretty steep for small diameters
         if PhlatScript.useMultipass?
            if step.abs > PhlatScript.multipassDepth
               step = -PhlatScript.multipassDepth
               step = StepFromMpass(zstart,zend,step)
               puts " ramp step #{step.to_mm} limited to multipass"       if (@debugramp)
            end
         else
            if step.abs > (@bit_diameter/2)
   #            s = ((zstart-zend) / (@bit_diameter/2)).ceil   
   #            step = -(zstart-zend) / s
               step = StepFromBit(zstart,zend)                    # each spiral Z feed will be bit diameter/2 or slightly less
               puts " ramp step #{step.to_mm} limited to fuzzybitdiam/2"       if (@debugramp)
            end
         end
      else
         if PhlatScript.useMultipass?
            step = -PhlatScript.multipassDepth
            puts "step from mpass was #{step}" if @debug
            step = StepFromMpass(zstart,zend,step)                      # possibly recalculate step to have equal sized steps
            puts "   became #{step}" if @debug
         else
            puts "step from bit" if @debug
            step = StepFromBit(zstart,zend)                       # each spiral Z feed will be bit diameter/2 or slightly less
            puts "   became #{step}" if @debug
         end
      end
      mpass = -step
      d = zstart-zend
      puts("SpiralatQ: zstep #{step.to_mm} zstart #{zstart.to_mm} zend #{zend.to_mm}  depth #{d.to_mm}" )   if @debug
      command_out += "   (Z step #{sprintf('%0.3f',step.to_mm)})\n"          if @debug
      now = zstart
      prevz = now
      while now > zend do
         now += step  #step is negative!
         if (now < zend)
            now = zend
         else
            df = zend - now # must prevent this missing the last spiral on small mpass depths, ie when mpass < bit/8
            if (df.abs < 0.001) #make sure we do not repeat the last pass
               now = zend
            else
               if ( df.abs < (mpass / 4) )
                  if (df < 0) #sign is important
                     command_out += "   (SpiralAt: forced depth as very close now #{now.to_mm} zend #{zend.to_mm}" if @debug
                     command_out += format_measure("df",df) + ")\n"                if @debug
                     now = zend
                  end
               end
            end
         end
         zdiff = (prevz - now) /4   # how much to feed on each quarter circle
#         command_out += "   (Z diff #{zdiff.to_mm})\n"          if @debug

         if (@cw)
            #x-o y I0 Jo
            command_out += "#{cmd}"
            command_out += format_measure("X",xo - yoff) + format_measure(" Y",yo)
            command_out += format_measure("Z",prevz - zdiff)
            command_out += " I0"  + format_measure(" J",yoff)
            if (feed != @cs)
               command_out += format_feed(@cs)  
               feed = @cs
            end
            command_out += "\n"
            #x y+O IOf J0
            command_out += "#{cmd}"
            command_out += format_measure("X",xo) + format_measure(" Y",yo+yoff)
            command_out += format_measure("Z",prevz - (zdiff*2))
            command_out += format_measure("I",yoff)  + format_measure(" J",0)
            command_out += "\n"
            #x+of Y I0 J-of
            command_out += "#{cmd}"
            command_out += format_measure("X",xo+yoff) + format_measure(" Y",yo)
            command_out += format_measure("Z",prevz - (zdiff*3))
            command_out += format_measure("I",0)  + format_measure(" J",-yoff)
            command_out += "\n"
            #x Y-of I-of J0
            command_out += "#{cmd}"
            command_out += format_measure("X",xo) + format_measure(" Y",yo-yoff)
            command_out += format_measure("Z",prevz - (zdiff*4))
            command_out += format_measure("I",-yoff)  + format_measure(" J",0)
            command_out += "\n"
         else
            #x+of Y  I0 Jof
            command_out += "#{cmd}"
            command_out += format_measure("X",xo + yoff) + format_measure(" Y",yo)
            command_out += format_measure("Z",prevz - zdiff)
            command_out += format_measure("I",0)  + format_measure(" J",yoff)
            if (feed != @cs)
               command_out += format_feed(@cs)  
               feed = @cs
            end
            command_out += "\n"
            #x Yof   I-of  J0
            command_out += "#{cmd}"
            command_out += format_measure("X",xo) + format_measure(" Y",yo+yoff)
            command_out += format_measure("Z",prevz - zdiff*2)
            command_out += format_measure("I",-yoff)  + format_measure(" J",0)
            command_out += "\n"
            #X-of  Y  I0    J-of
            command_out += "#{cmd}"
            command_out += format_measure("X",xo-yoff) + format_measure(" Y",yo)
            command_out += format_measure("Z",prevz - zdiff*3)
            command_out += format_measure("I",0)  + format_measure(" J",-yoff)
            command_out += "\n"
            #X  Y-of  Iof   J0
            command_out += "#{cmd}"
            command_out += format_measure("X",xo) + format_measure(" Y",yo-yoff)
            command_out += format_measure("Z",now) #prevz - zdiff*4)
            command_out += format_measure("I",yoff)  + format_measure(" J",0)
            command_out += "\n"
         end
         prevz = now
      end # while
    # now the bottom needs to be flat at $depth
      command_out += "(flatten bottom)\n" if @debug
      if (@cw)
            #x-o y I0 Jo
            command_out += "#{cmd}"
            command_out += format_measure("X",xo - yoff) + format_measure("Y",yo) + " I0"  + format_measure("J",yoff)
            command_out += "\n"
            #x y+O IOf J0
            command_out += "#{cmd}"
            command_out += format_measure("X",xo) + format_measure("Y",yo+yoff) + format_measure("I",yoff)  + format_measure("J",0)
            command_out += "\n"
            #x+of Y I0 J-of
            command_out += "#{cmd}"
            command_out += format_measure("X",xo+yoff) + format_measure("Y",yo) + format_measure(" I",0)  + format_measure("J",-yoff)
            command_out += "\n"
            #x Y-of I-of J0
            command_out += "#{cmd}"
            command_out += format_measure("X",xo) + format_measure("Y",yo-yoff) + format_measure("I",-yoff)  + format_measure("J",0)
            command_out += "\n"
         else
            #x+of Y  I0 Jof
            command_out += "#{cmd}"
            command_out += format_measure("X",xo + yoff) + format_measure("Y",yo) + format_measure("I",0)  + format_measure("J",yoff)
            command_out += "\n"
            #x Yof   I-of  J0
            command_out += "#{cmd}"
            command_out += format_measure("X",xo) + format_measure("Y",yo+yoff) + format_measure("I",-yoff)  + format_measure("J",0)
            command_out += "\n"
            #X-of  Y  I0    J-of
            command_out += "#{cmd}"
            command_out += format_measure("X",xo-yoff) + format_measure("Y",yo) + format_measure("I",0)  + format_measure("J",-yoff)
            command_out += "\n"
            #X  Y-of  Iof   J0
            command_out += "#{cmd}"
            command_out += format_measure("X",xo) + format_measure("Y",yo-yoff) + format_measure("I",yoff)  + format_measure("J",0)
            command_out += "\n"
         end
      command_out += "   (SPIRALatQ END)\n" if @debug
      @precision -= 1
#   @debugramp = false
      return command_out
    end # SpiralAtQ

# generate code for a spiral bore and return the command string, using quadrants
# this one does center out to diameter, an outward spiral at zo depth
# must give it the final yoff, call it after doing the initial 2D bore.
   def SpiralOut(xo,yo,zstart,zend,yoff,ystep)
   #@debugramp = true
      @precision += 1
#      cwstr = @cw ? 'CW' : 'CCW';
#      cmd =   @cw ? 'G02': 'G03';
      cwstr = 'CCW'
      cmd = 'G03'   # spiral out can only do this
      command_out = ""
      command_out += "   (SPIRALOUT #{xo.to_mm},#{yo.to_mm},#{(zstart-zend).to_mm},#{yoff.to_mm},#{cwstr})\n" if @debugramp
      
#cutpoint is 1/2 bit out from the center, at zend depth
      
#      command_out += "G00" + format_measure("Y",yo-yoff) + "\n"
#      command_out += "   " + format_measure("Z",zstart+0.5.mm) + "\n"   # rapid to near surface
#      command_out += "G01" + format_measure("Z",zstart) # feed to surface
#      command_out += format_feed(@speed_curr)    if (@speed_curr != @cs)
#      command_out += "\n"
      
      #we are at zend depth
      #we need to spiral out to yoff
      yfinal = yo - yoff
      ynow = yo - @bit_diameter / 2
      puts "  yo #{yo.to_mm} (yfinal #{yfinal.to_mm} ynow #{ynow.to_mm} ystep #{ystep.to_mm})"        if @debug
      cnt = 0
      while ((ynow - yfinal).abs > 0.0001)
         
         # spiral from ynow to ynow-ystep
         yother = yo + (yo-ynow) + ystep/2
         puts "   ynow #{ynow.to_mm}    yother #{yother.to_mm}" if @debug
         ynew = ynow - ystep
         if (ynew < (yo-yoff)  ) 
            command_out += "(ynew clamped)\n"   if @debug
            puts "ynew clamped"                 if @debug
            ynew = yo - yoff 
         end
         #R format - cuts correctly but does not display correctly in OpenSCAM, nor Gplot
#         command_out += 'G03' + format_measure('Y',yother) + format_measure('R', (yother-ynow)/2) +"\n"
#         command_out += 'G03' + format_measure('Y',ynew) + format_measure('R', (yother-ynew)/2 ) +"\n"
         #IJ format - displays correctly in OpenSCAM, not Gplot
         command_out += 'G03' + format_measure('Y',yother) + " I0" + format_measure('J', (yother-ynow)/2) +"\n"
         command_out += 'G03' + format_measure('Y',ynew)   + " I0" + format_measure('J', -(yother-ynew)/2 ) +"\n"

         ynow = ynow - ystep
         if (ynow < (yo-yoff)  ) 
            command_out += "(ynow clamped)\n"         if @debug
            ynow = yo - yoff 
         end
         cnt += 1
         if (cnt > 1000)
            puts "SpiralOut high count break"
            cncPrint("Error: spiralout high coutn break")
            break
         end
      end
      puts "   final ynow #{ynow.to_mm}"        if @debug
      
      #now make it full diameter
      #x+of Y  I0 Jof
      command_out += "#{cmd}"
      command_out += format_measure("X",xo + yoff) + format_measure("Y",yo) + format_measure("I",0)  + format_measure("J",yoff)
      command_out += "\n"
      #x Yof   I-of  J0
      command_out += "#{cmd}"
      command_out += format_measure("X",xo) + format_measure("Y",yo+yoff) + format_measure("I",-yoff)  + format_measure("J",0)
      command_out += "\n"
      #X-of  Y  I0    J-of
      command_out += "#{cmd}"
      command_out += format_measure("X",xo-yoff) + format_measure("Y",yo) + format_measure("I",0)  + format_measure("J",-yoff)
      command_out += "\n"
      #X  Y-of  Iof   J0
      command_out += "#{cmd}"
      command_out += format_measure("X",xo) + format_measure("Y",yo-yoff) + format_measure("I",yoff)  + format_measure("J",0)
      command_out += "\n"
      @cc = cmd
      command_out += "   (SPIRAL END)\n" if @debug
      @precision -= 1
   #@debugramp = false
      return command_out
   end # SpiralOut
    
    
# take the existing diam and ystep and possibly modify the ystep to get an exact number of steps
# if stepover is 50% then do nothing
# if ystep will use up all the remainder space, do not change
# if stepover < 50 then make ystep smaller
# if stepover > 50% make ystep larger
   def GetFuzzyYstep(diam,ystep, mustramp, force)
#   @debug = true
      if (mustramp)
         rem = (diam / 2) - (@bit_diameter)  # still to be cut, we have already cut a 2*bit hole
      else
         rem = (diam / 2) - (@bit_diameter/2) # have drilled a bit diam hole
      end
      temp = rem / ystep   # number of steps to do it
      puts "   getfuzzystep diam #{diam.to_mm} temp steps = #{temp}  ystep old #{ystep.to_mm} remainder #{rem.to_mm}\n" if @debug
      if (temp < 1.0)
         puts "   getfuzzystep   not going to bother making it smaller"  if @debug
         if (ystep  > rem)
            ystep = rem
            puts "   getfuzzystep    ystep set to remainder" if @debug
         end
         return ystep
      end
      oldystep = ystep  
      flag = false
      if ((PhlatScript.stepover < 50) || force)               #round temp up to create more steps-
         temp = (temp + 0.5).round
         flag = true
      else
         if (PhlatScript.stepover > 50)            #round temp down to create fewer steps
            temp = (temp - 0.5).round
            flag = true
         else
            if (force)
               temp = (temp + 0.5).round
               flag = true
            end
         end
      end
      if (flag)                                    # only adjust if we need to
         temp = (temp < 1) ? 1 : temp
         puts "   getfuzzystep   new temp steps = #{temp}\n" if @debug
         #   calc new ystep
         ystep = rem / temp
         
         if (ystep > @bit_diameter ) # limit to stepover
            if (force)
               while (ystep > @bit_diameter)
                  temp += 1
                  ystep = rem /temp
                  puts "   getfuzzystep    ystep was > bit, recalculated with force #{temp}\n"         if @debug
               end
            else   
               ystep = PhlatScript.stepover * @bit_diameter / 100
               puts "   getfuzzystep    ystep was > bit, limited to stepover\n"         if @debug
            end
            
         end
         puts "   getfuzzystep ystep new #{ystep.to_mm}\n" if @debug
         if oldystep != ystep
            cncPrintC("OLD STEP #{oldystep.to_mm} new step #{ystep.to_mm}")  if (@debug)
         end
      end
      if (ystep > rem)
         puts "yste > rem, trimming to rem" if @debug
         ystep =  rem
      end
#   @debug = false         
      return ystep
   end
   
   #select between the plungebore options and call the correct method
   def plungebore(xo,yo,zStart,zo,diam, ang=0, cdiam = 0, cdepth = 0)   
      if (ang > 0)
         plungecsink(xo,yo,zStart,zo,diam, ang, cdiam)      if (cdiam > 0.0)
         UI.messagebox('ERROR: cdiam < 0 in plungecsink')   if (cdiam < 0.0)
      else
         if (ang < 0)
            plungeCbore(xo,yo,zStart,zo,diam, ang, cdiam,cdepth)  if ((cdiam > 0.0) &&  (cdepth > 0.0))
            UI.messagebox('ERROR: cdiam < 0 in plungecBore')      if ((cdiam < 0.0) &&  (cdepth < 0.0))
         else
            if @depthfirst then
               plungeboredepth(xo,yo,zStart,zo,diam)
            else
               plungeborediam(xo,yo,zStart,zo,diam)
            end
         end
      end
   end
   
   #circles for plingecsink - use for <= 2*bitdiam
   def circle(xo,yo, znow, rnow, complete=true)
      out = '' # 'G00' + format_measure('X',xo) + format_measure('Y',yo) + "\n"
      rad = rnow - @bit_diameter / 2.0
      if (rad <= 0.1.mm)
         return ''
      end
      #arc into the cut
      if complete
         out += 'G03' + format_measure('X', xo) + format_measure('Y',yo-rad) +format_measure('Z',znow) + format_measure('I',0)+ format_measure('J',-rad/2.0)
         if (@cs != @speed_plung)
            out += format_feed(@speed_plung)
            @cs = @speed_plung
         end
         out += "\n"
      else
         out += 'G01' + format_measure('Y', yo-rad) + "\n"
      end
#      out += 'G03' + format_measure('X', xo-rad) + format_measure('Y',yo) + format_measure('R',rad) + "\n"
      #cut a full circle in quadrants
      out += "G03" + format_measure("X",xo + rad) + format_measure("Y",yo) + format_measure("I",0)  + format_measure("J",rad)
      if (@cs != @speed_curr)
         out += format_feed(@speed_curr)
         @cs = @speed_curr
      end
      out += "\n"      
      out += "G03" + format_measure("X",xo) + format_measure("Y",yo+rad) + format_measure("I",-rad)  + format_measure("J",0) + "\n"
      out += "G03" + format_measure("X",xo-rad) + format_measure("Y",yo) + format_measure("I",0)  + format_measure("J",-rad) + "\n"
      out += "G03" + format_measure("X",xo) + format_measure("Y",yo-rad) + format_measure("I",rad)  + format_measure("J",0) + "\n"
      return out
   end
   
   def plungecsink(xo,yo,zStart,zo,diam, ang, cdiam)
      #@debug = true
      cncPrintC("plungeCSINK #{sprintf('X%0.2f',xo.to_mm)},#{sprintf('Y%0.2f',yo.to_mm)},zs #{sprintf('%0.2f',zStart.to_mm)},zo #{sprintf('%0.3f',zo.to_mm)}")
      cncPrintC("diam #{sprintf('%0.2f',diam.to_mm)}, #{sprintf('%0.2fdeg',ang)}, #{sprintf('cdiam %0.2f',cdiam.to_f.to_mm)}")
      
      #first drill the center hole
      cncPrint("(plunge the hole)\n")        if @debug
      ucwas = $phoptions.usecomments?
      $phoptions.usecomments = false         if !@debug
      plungebore(xo, yo, zStart, zo, diam)
      $phoptions.usecomments = ucwas
      cncPrint("(end of plunge)\n")          if @debug
      
      outR = cdiam.to_f / 2.0 # radius to cut to
      downS = 0.25.mm  # step down for each layer
      alpha = ang / 2.0 # side wall angle - in degrees
      xf = Math::tan(torad(alpha)) * downS   # x step to reduce radius by each step
      puts "outR #{outR.to_mm}"     if @debug
      puts "downS #{downS.to_mm}"   if @debug
      puts "alpha #{alpha}"         if @debug
      puts "xf #{xf.to_mm}"         if @debug
      if (xf > @bit_diameter)
         xf = @bit_diameter / 2
      end
      hbd = @bit_diameter / 2
      rNow = outR                # starting radius
      rEnd = [diam/2.0, @bit_diameter / 2.0].max # stop when less than this
      puts "rEnd #{rEnd.to_l.to_s}"                                                    if @debug
      
      zNow = zStart
      output = "G00" + format_measure("Z",zStart+0.02) + "\n"   # rapid to near surface - should be a hole there!
      output += "G01" + format_measure("Z",zStart) + format_feed(@speed_plung) + "\n"
      
      #@speed_curr  = PhlatScript.feedRate
      #@speed_plung = PhlatScript.plungeRate      
      @cs = @speed_plung
      
      zEnd =  zStart - @material_thickness
      puts "zEnd #{zEnd}"                                                              if @debug

      while rNow > rEnd do
         zNow -= downS
         
         if (zNow - zEnd) <= 0.001
            puts "not going deeper than material"                                      if @debug
            break
         end
         puts "circle znow #{zNow.to_mm} Rnow #{rNow.to_mm}"                           if @debug
         
         ynow = 0
         cnt = 0
         if (rNow) <= (@bit_diameter) # radius less than bitdiam === diam < 2*bitdiam
            output += "(plain)\n"                                                      if @debug
            output += 'G00' + format_measure('X',xo) + format_measure('Y',yo) + "\n"
            output += 'G00' + format_measure('Z',zNow + downS) + "\n"      if (cnt != 0)
            circ = circle(xo,yo,zNow,rNow)
            if (circ != "")
               output += circ
               output += 'G00' + format_measure('Z',zNow + 0.002) + "\n"
            end
            output += "(plain done)\n"                                                 if @debug
         else
            output += "(stepped for #{rNow.to_mm} )\n"                                 if @debug
            output += 'G00' + format_measure('X',xo) + format_measure('Y',yo) + "\n"
            output += circle(xo,yo,zNow,@bit_diameter)  # first cut 2xbit hole
            output += "(spiral rNow #{rNow.to_mm})\n"                                  if @debug
            ystep = PhlatScript.stepover * @bit_diameter / 100
            ystep = GetFuzzyYstep(rNow*2,ystep, true, true).abs   # mustramp false to start from bitdiam hole
            puts "ystep #{ystep.to_mm}"                                                if @debug
            output += SpiralOut(xo,yo,zStart,zNow,rNow-hbd,ystep)  # now spiralout from there
            output += 'G00' + format_measure('Z',zNow + 0.002) + "\n"
            output += "(spiral rNow #{rNow.to_mm} done)\n"                             if @debug
         end
         rNow -= xf
         cnt += 1
      end # while

      output += "G00" + format_measure("Y",yo)      # back to circle center
      output += format_measure(" Z",@retract_depth) # retract to real safe height
      output += "\n"
      cncPrint(output)
#      @debug = false
   end

# beta testers wanted a counterbore option, so here it is
# ang will be -90
   def plungeCbore(xo,yo,zStart,zo,diam, ang, cdiam, cdepth)
      #@debug = true
      if (@debug)
         cncPrintC("plungeCBORE #{sprintf('X%0.2f',xo.to_mm)},#{sprintf('Y%0.2f',yo.to_mm)},zs #{sprintf('%0.2f',zStart.to_mm)},zo #{sprintf('%0.2f',zo.to_mm)}")
         cncPrintC("   diam#{sprintf('%0.2f',diam.to_mm)}, cdiam #{sprintf('%0.2f',cdiam.to_f.to_mm)}, cdepth #{sprintf('%0.2f',cdepth.to_f.to_mm)}")
      else
         cncPrintC("plungeCBORE diam#{sprintf('%0.3f',diam.to_mm)}, cdiam #{sprintf('%0.3f',cdiam.to_f.to_mm)}, cdepth #{sprintf('%0.3f',cdepth.to_f.to_mm)}")
      end
      
      #first drill the center hole
      cncPrintC("(plunge the hole)\n")          if @debug
      ucwas = $phoptions.usecomments?
      $phoptions.usecomments = false            if !@debug
      plungebore(xo, yo, zStart, zo, diam)
      $phoptions.usecomments = ucwas
      cncPrintC("(end of plunge)\n")            if @debug
      
      #now do the counterbore
      cncPrintC("(plunge the cbore )\n")        if @debug
      puts "cdepth #{cdepth} cdiam #{cdiam}"    if @debug
      oldramp = PhlatScript.mustramp?
      if (!oldramp)  # ramp not on, set angle to 0
         oldangle = PhlatScript.rampangle
         PhlatScript.rampangle = 0
      end
      PhlatScript.mustramp = true   # force ramping on to avoid center drill cycle
      ucwas = $phoptions.usecomments?
      $phoptions.usecomments = false            if !@debug
      plungebore(xo, yo, zStart, zStart-cdepth.to_f, cdiam.to_f)
      $phoptions.usecomments = ucwas      
      PhlatScript.mustramp = oldramp
      if (!oldramp)   # if it was off, reset the angle
         PhlatScript.rampangle = oldangle
      end
      cncPrintC("cbore done\n")      
      
=begin
      output = "G00" + format_measure("Y",yo)      # back to circle center
      output += format_measure(" Z",@retract_depth) # retract to real safe height
      output += "\n"
      cncPrint(output)
=end      
      #@debug = false
   end
   
   
#swarfer: instead of a plunged hole, spiral bore to depth, depth first (the old way)
#handles multipass by itself, also handles ramping
   def plungeboredepth(xo,yo,zStart,zo,diam)
   #@debug = true
      zos = format_measure("depth=",(zStart-zo))
      ds = format_measure(" diam=", diam)
      cncPrintC("(plungebore #{zos} #{ds})\n")
      if (zo > @max_z)
        zo = @max_z
      elsif (zo < @min_z)
        zo = @min_z
      end
      command_out = ""

      cncPrintC("HOLEdepth #{sprintf('%0.2f',diam.to_mm)} dia at #{sprintf('%0.2f',xo.to_mm)},#{sprintf('%0.2f',yo.to_mm)} DEPTH #{sprintf('%0.2f',(zStart-zo).to_mm)}\n")       if @debug
      puts     " (HOLEdepth #{diam.to_mm} dia at #{xo.to_mm},#{yo.to_mm} DEPTH #{(zStart-zo).to_mm})\n"       if @debug

#      xs = format_measure('X', xo)
#      ys = format_measure('Y', yo)
#      command_out += "G00 #{xs} #{ys}\n";
#swarfer: a little optimization, approach the surface faster
      if ($phoptions.use_reduced_safe_height?) 
         sh = (@retract_depth - zStart) / 4 # use reduced safe height
         sh = (sh > 0.5.mm) ? 0.5.mm : sh
         if zStart > 0
            sh += zStart.to_f
         end
         if (!@canneddrill) || (PhlatScript.mustramp?) 
            puts "pbd  reduced safe height #{sh.to_mm}\n"                     if @debug
            command_out += "G00" + format_measure("Z", sh)    # fast feed down to safe height
            @cz = sh
            command_out += "\n"
         end
      else
         sh = @retract_depth
      end

      so = @speed_plung                     # force using plunge rate for vertical moves
      if PhlatScript.useMultipass?
         if ( (PhlatScript.mustramp?) && (diam > @bit_diameter) )
            flag = false
            if (diam > (@bit_diameter*2))
               yoff = @bit_diameter / 2
               flag = true
               if (@quarters)
                  command_out += SpiralAtQ(xo,yo,zStart,zo, yoff )
               else
                  command_out += SpiralAt(xo,yo,zStart,zo, yoff )
               end
            else
               if (PhlatScript.stepover < 50)  # act for a hard material
                  yoff = (diam/2 - @bit_diameter/2) * 0.7
                  flag = true
                  if (@quarters)
                     command_out += SpiralAtQ(xo,yo,zStart,zo, yoff )
                  else
                     command_out += SpiralAt(xo,yo,zStart,zo, yoff )
                  end
               end
            end
            if flag
               command_out += "G00" + format_measure("Y" , yo - yoff/2) + format_measure("Z" , sh) + "\n"
            end
         else  # diam = biadiam OR not ramping
            zonow = PhlatScript.tabletop? ? @material_thickness : 0
            if (@canneddrill)
               command_out += (diam > @bit_diameter) ? "G99" : "G98"
               command_out += " G83"
               command_out += format_measure("X",xo)
               command_out += format_measure("Y",yo )
               command_out += format_measure("Z",zo )
               command_out += format_measure("R",sh )                         # retract height
               command_out += format_measure("Q",PhlatScript.multipassDepth)  # peck depth
               if (so != @cs)
                  command_out += (format_feed(so))
                  @cs = so
               end
               command_out += "\n"               
               command_out += "G80\n";
            else # manual peck drill cycle
               while (zonow - zo).abs > 0.0001 do
                  zonow -= PhlatScript.multipassDepth
                  if zonow < zo
                     zonow = zo
                  end
                  command_out += "G01" + format_measure("Z",zonow)  # plunge the center hole
                  if (so != @cs)
                     command_out += (format_feed(so)) 
                     @cs = so
                  end
                  command_out += "\n"
                  
                  if (zonow - zo).abs < 0.0001  # if at bottom, then retract
                     command_out += "G00" + format_measure("z",sh) + "\n"    # retract to reduced safe
                  else
                     if (@quickpeck)
                        raise = (PhlatScript.multipassDepth <= 0.5.mm) ? PhlatScript.multipassDepth / 2 : 0.5.mm
                        if (raise < 0.1.mm)
                           raise = 0.1.mm
                        end
                        command_out += "G00" + format_measure("z",zonow + raise) + "\n" # raise just a smidge  
                     else
                        command_out += "G00" + format_measure("z",sh) + "\n"    # retract to reduced safe
                     end
                  end
               end #while
            end # else canneddrill
         end
      else
#todo - if ramping, then do not plunge this, rather do a spiralat with yoff = bit/2      
#more optimizing, only bore the center if the hole is big, assuming soft material anyway
         if ((diam > @bit_diameter) && (PhlatScript.mustramp?))
            flag = false
            if (diam > (@bit_diameter*2))
               yoff = @bit_diameter / 2
               flag = true
               cncPrintC("!multi && ramp yoff #{yoff.to_mm}")  if (@debug)
               if (@quarters)
                  command_out += SpiralAtQ(xo,yo,zStart,zo, yoff )
               else
                  command_out += SpiralAt(xo,yo,zStart,zo, yoff )
               end
            else
               if (PhlatScript.stepover < 50)  # act for a hard material, do initial spiral 
                  yoff = (diam/2 - @bit_diameter/2) * 0.7
                  flag = true
                  cncPrintC("!multi && ramp 0.7 Yoff #{yoff.to_mm}")  if (@debug)
                  if (@quarters)
                     command_out += SpiralAtQ(xo,yo,zStart,zo, yoff )
                  else
                     command_out += SpiralAt(xo,yo,zStart,zo, yoff )
                  end
               end
            end
            command_out += "G00" + format_measure("Y" , yo - yoff/2) + format_measure("Z" , sh) + "\n"         if flag
         else
            if (@canneddrill)
               if (diam > @bit_diameter)  # then prepare for multi spirals by retracting to reduced height
#                  command_out += "G00" + format_measure("Z", sh)    # fast feed down to 1/3 safe height
#                  command_out += "\n"
                  command_out += "G99 G81"  #drill with dwell  - gplot does not like this!
               else
                  command_out += "G98 G81"  #drill with dwell  - gplot does not like this!
               end
               command_out += format_measure("X",xo)
               command_out += format_measure("Y",yo )
               command_out += format_measure("Z",zo )
               command_out += format_measure("R",sh )
#               command_out += format_measure("P",0.2/25.4)               # dwell 1/5 second
#               command_out += format_measure("Q",PhlatScript.multipassDepth)
               if (so != @cs)
                  command_out += (format_feed(so)) 
                  @cs = so
               end
               command_out += "\n"               
               command_out += "G80\n";
            else
               command_out += "G01" + format_measure("Z",zo)  # plunge the center hole
               if (so != @cs)
                  command_out += format_feed(so)
                  @cs = so
               end
               command_out += "\n"
               command_out += "G00" + format_measure("z",sh)    # retract to reduced safe
               command_out += "\n"
            end
            @cs = so

         end
      end

    # if DIA is > 2*BITDIA then we need multiple cuts
      yoff = (diam/2 - @bit_diameter/2)      # offset to start point for final cut
      if (diam > (@bit_diameter*2) )
         command_out += "  (MULTI spirals)\n"            if @debug
# if regular step         
#         ystep = @bit_diameter / 2
# else use stepover
         ystep = PhlatScript.stepover * @bit_diameter / 100

#########################
# if fuzzy stepping, calc new ystep from optimized step count
# find number of steps to complete hole
         if ($phoptions.use_fuzzy_holes?)
            ystep = GetFuzzyYstep(diam,ystep, PhlatScript.mustramp?, false)
         end
#######################

         puts "Ystep #{ystep.to_mm}\n" if @debug
         
         nowyoffset = (PhlatScript.mustramp?) ? @bit_diameter/2 :  0
#         while (nowyoffset < yoff)
         while ( (nowyoffset - yoff).abs > 0.0001)         
            nowyoffset += ystep
            if (nowyoffset > yoff)
               nowyoffset = yoff
               command_out += "  (offset clamped)\n"                 if @debug
               puts "   nowyoffset #{nowyoffset.to_mm} clamped\n"    if @debug
            else
               puts "   nowyoffset #{nowyoffset.to_mm}\n"            if @debug
            end
            
            command_out += (@quarters) ? SpiralAtQ(xo,yo,zStart,zo,nowyoffset) : SpiralAt(xo,yo,zStart,zo,nowyoffset)

            #            if (nowyoffset != yoff) # then retract to reduced safe
            if ( (nowyoffset - yoff).abs > 0.0001) # then retract to reduced safe            
               command_out += "G00" + format_measure("Y" , yo - nowyoffset + ystep/2) + format_measure("Z" , sh)
               command_out += "\n"
            end
         end # while
      else
         if (diam > @bit_diameter) # only need a spiral bore if desired hole is bigger than the drill bit
            puts " (SINGLE spiral)\n"                    if @debug
            command_out += (@quarters) ? SpiralAtQ(xo,yo,zStart,zo,yoff) : SpiralAt(xo,yo,zStart,zo,yoff)
         end
         if (diam < @bit_diameter)
            cncPrintC("NOTE: requested dia #{diam} is smaller than bit diameter #{@bit_diameter}")
         end
      end # if diam >

      # return to center at safe height
#      command_out += format_measure(" G1 Y",yo)
#      command_out += "\n";
      command_out += "G00" + format_measure("Y",yo)      # back to circle center
      command_out += format_measure(" Z",@retract_depth) # retract to real safe height
      command_out += "\n"
      cncPrint(command_out)
      
      cncPrintC("plungebore end")

      @cx = xo
      @cy = yo
      @cz = @retract_depth
      @cs = so
      @cc = '' #resetting command here so next one is forced to be correct
   #@debug = false   
   end
   
#swarfer: instead of a plunged hole, spiral bore to depth, doing diameter first with an outward spiral
#handles multipass by itself, also handles ramping
# this is different enough from the old plunge bore that making it conditional within 'plungebore' would make it too complicated
   def plungeborediam(xo,yo,zStart,zo,diam)
   #@debug = true
      zos = format_measure("depth=",(zStart-zo))
      ds = format_measure(" diam=", diam)
      if (diam > (2*@bit_diameter))
         cncPrintC("(plungeboreDiam #{zos} #{ds})\n")
      end
      if (zo > @max_z)
        zo = @max_z
      elsif (zo < @min_z)
        zo = @min_z
      end
      command_out = ""

      cncPrintC("HOLEdiam #{sprintf('%0.2f',diam.to_mm)} dia at #{sprintf('X%0.2f',xo.to_mm)},#{sprintf('Y%0.2f',yo.to_mm)} DEPTH #{sprintf('%0.2f',(zStart-zo).to_mm)}\n")       if @debug
      puts     " (HOLEdiam #{diam.to_mm} dia at #{xo.to_mm},#{yo.to_mm} DEPTH #{(zStart-zo).to_mm})\n"       if @debug

#      xs = format_measure('X', xo)
#      ys = format_measure('Y', yo)
#      command_out += "G00 #{xs} #{ys}\n";
#swarfer: a little optimization, approach the surface faster
      if ($phoptions.use_reduced_safe_height?) 
         sh = (@retract_depth - zStart) / 4 # use reduced safe height
         sh = (sh > 0.5.mm) ? 0.5.mm : sh
         if zStart > 0
            sh += zStart.to_f
         end
         if (!@canneddrill) || (PhlatScript.mustramp?) 
            puts "  reduced safe height #{sh.to_mm}\n"                     if @debug
            command_out += "G00" + format_measure("Z", sh)    # fast feed down to 1/3 safe height
            command_out += "\n"
            @cz = sh
         end
      else
         sh = @retract_depth
      end

      so = @speed_curr     #spiral at normal feed speed
      
      bd2 = 2*@bit_diameter
      if ( (diam < bd2) || ((bd2 - diam).abs < 0.0005) )  #just do the ordinary plunge, no need to handle it here
         puts "diam < 2bit - reverting to depth"      if @debug
         return plungeboredepth(xo,yo,zStart,zo,diam)
      end
      #SO IF WE ARE HERE WE KNOW DIAM > 2*BIT_DIAMETER
      
      #bore the center out now
      yoff = @bit_diameter / 2
      command_out += "(plungediam: do center)\n" if @debug
      command_out += (@quarters) ? SpiralAtQ(xo,yo,zStart,zo, yoff ) : SpiralAt(xo,yo,zStart,zo, yoff )
      command_out += 'G00' + format_measure('Y', yo) + "\n"
      command_out += "(plungediam: center bore complete)\n"       if @debug
#      command_out += "G00" + format_measure("Z" , sh)
#     command_out += "\n"
      

    # if DIA is > 2*BITDIA then we need multiple cuts
      yoff = (diam/2 - @bit_diameter/2)      # offset to start point for final cut

      command_out += "  (spiral out)\n"            if @debug
      ystep = PhlatScript.stepover * @bit_diameter / 100
      puts "Ystep #{ystep.to_mm}\n" if @debug
#for outward spirals we are ALWAYS using fuzzy step so each spiral is the same size
      ystep = GetFuzzyYstep(diam,ystep, true, true)   # force mustramp true to get correct result

      puts "Ystep fuzzy #{ystep.to_mm}\n" if @debug
      
      nowyoffset = @bit_diameter/2
      
      if PhlatScript.useMultipass?
         #command_out += "G00" + format_measure("Z" , sh)
         #command_out += "\n"
         zstep = -PhlatScript.multipassDepth
         zstep = StepFromMpass(zStart,zo,zstep)
      else
         zstep = -(zStart-zo)
      end   
      
      puts "zstep = #{zstep.to_mm}"  if @debug
      cnt = 0 
      zonow = PhlatScript.tabletop? ? @material_thickness : 0
      while (zonow - zo).abs > 0.0001 do
         zonow += zstep  # zstep is negative
         if zonow < zo
            zonow = zo
         end
         #puts "   zonow #{zonow.to_mm}"
#         command_out += "G01"  + format_measure('Y', yo - @bit_diameter/2) + format_measure("Z",zonow)
         command_out += "G00"  + format_measure('Z', zonow) + "\n"
         @precision += 1
         #arc from center to start point
         command_out += "G03" +  format_measure('Y', yo - @bit_diameter/2) + format_measure('I0.0 J', -@bit_diameter/4)
         @precision -= 1
         if (so != @cs)
            puts "so #{so}  @cs #{@cs}"      if @debug
            command_out += format_feed(so)
            @cs = so
            puts "   so #{so}  @cs #{@cs}"   if @debug
         end
         command_out += "\n"
         
         command_out += SpiralOut(xo,yo,zStart,zonow,yoff,ystep)
         if PhlatScript.useMultipass? &&  ((zonow - zo).abs > 0.0001)
#            command_out += "G00" + format_measure('Y', yo - @bit_diameter/2 + 0.005) + "\n"
#            command_out += "G00" + format_measure('Y', yo - @bit_diameter/2+ 0.005) + format_measure('Z',zonow + 0.02) + "\n"
            command_out += "G00" + format_measure('Z',zonow + 0.02) + "\n"    # raise
            command_out += "G00" + format_measure('Y', yo) + "\n"             # back to hole center
         end
         cnt += 1
         if cnt > 1000
            cncPrint("error high count break in plungeborediam")
            break
         end
      end #while      

      # return to center at safe height
      command_out += "(return to safe center)\n" if @debug
      command_out += "G00" + format_measure("Y",yo)      # back to circle center
      command_out += format_measure(" Z",@retract_depth) # retract to real safe height
      command_out += "\n"
      cncPrint(command_out)
      
      cncPrintC("plungeborediam end")

      @cx = xo
      @cy = yo
      @cz = @retract_depth
      @cs = so
      @cc = '' #resetting command here so next one is forced to be correct
   #@debug = false   
   end

# use R format arc movement, suffers from accuracy and occasional reversal by CNC controllers
# if radius is <= 0.006.inch then output a linear move since really small radii cause issues with controllers and simulators
   def arcmove(xo, yo=@cy, radius=0, g3=false, zo=@cz, so=@speed_curr, cmd=@cmd_arc)
      cmd = @cmd_arc_rev if g3
      #puts "g3: #{g3} cmd #{cmd}"
      #G17 G2 x 10 y 16 i 3 j 4 z 9
      #G17 G2 x 10 y 15 r 20 z 5
      command_out = ""
      if (radius > 0.01.inch)  # is radius big enough?
         command_out += cmd if ((cmd != @cc) || @gforce)
         @precision +=1  # circles like a bit of extra precision so output an extra digit
         command_out += (format_measure("X", xo)) #if (xo != @cx) x and y must be specified in G2/3 codes
         command_out += (format_measure("Y", yo)) #if (yo != @cy)
         command_out += (format_measure("Z", zo)) if (zo != @cz)   # optional Z motion
         command_out += (format_measure("R", radius))
         @precision -=1
         command_out += (format_feed(so)) if (so != @cs)
         command_out += "\n"
      else  # output a linear move instead
         command_out += "G01"
         cmd = "G01"
         command_out += (format_measure("X", xo)) #if (xo != @cx) x and y must be specified in G2/3 codes
         command_out += (format_measure("Y", yo)) #if (yo != @cy)
         command_out += (format_measure("Z", zo)) if (zo != @cz)
         command_out += (format_feed(so)) if (so != @cs)
         command_out += "\n"
      end
      cncPrint(command_out)
      @cx = xo
      @cy = yo
      @cz = zo
      @cs = so
      @cc = cmd
   end

# use IJ format arc movement, more accurate, definitive direction
   def arcmoveij(xo, yo, centerx,centery, g3=false, zo=@cz, so=@speed_curr, cmd=@cmd_arc)
      cmd = @cmd_arc_rev if g3
      #puts "g3: #{g3} cmd #{cmd}"
      #G17 G2 x 10 y 16 i 3 j 4 z 9
      #G17 G2 x 10 y 15 r 20 z 5
      command_out = ""
      command_out += cmd   if ((cmd != @cc) || @gforce)
      @precision +=1  # circles like a bit of extra precision so output an extra digit
      command_out += (format_measure("X", xo)) #if (xo != @cx) x and y must be specified in G2/3 codes
      command_out += (format_measure("Y", yo)) #if (yo != @cy)
      command_out += (format_measure("Z", zo)) if (zo != @cz)
      i = centerx - @cx
      j = centery - @cy
      command_out += (format_measure("I", i))
      command_out += (format_measure("J", j))
      @precision -=1
      command_out += (format_feed(so)) if (so != @cs)
      command_out += "\n"
      cncPrint(command_out)
      @cx = xo
      @cy = yo
      @cz = zo
      @cs = so
      @cc = cmd
   end


    def home
      if (@cz == @retract_depth) && (@cy == 0) && (@cx == 0)
        @no_move_count += 1
      else
        retract(@retract_depth)
        cncPrint("G00 X0 Y0 ")
        if ($phoptions.usecomments?)  
           cncPrint(PhlatScript.gcomment("home") )
        end   
        cncPrint("\n")
        @cx = 0
        @cy = 0
        @cz = @retract_depth
        @cs = 0
        @cc = ""
      end
    end

  end # class PhlatMill

end # module PhlatScript
# A forum member was struggling with a 1mm bit cutting 1mm hard material in that
# the plunge cuts after tabs were at full speed not plunge speed
# This file solves that, and is different from the first version published in that
# all upward Z moves are at fullspeed, only downward cuts are at plunge speed
# Vtabs are at full speed as usual.
# $Id$

=begin
      places = Array.new
      while rNow > rEnd do
         zNow -= downS
         if (zNow - zEnd) <= 0.001
            puts "not going deeper than material"
            break
         end
         puts "circle znow #{zNow.to_mm} Rnow #{rNow.to_mm}"
         #output += circle(xo,yo,zNow,rNow)
         places.push(zNow,rNow)
         rNow -= xf
      end # while

      while places.length > 0 do
         rNow = places.pop
         zNow = places.pop
         puts "places znow #{zNow.to_mm} Rnow #{rNow.to_mm}"
         #output += circle(xo,yo,zNow,rNow)
         output += SpiralAtQ(xo,yo,zStart,zNow,rNow)
         output += "g00" + format_measure("Z",zStart+0.02) + "\n"   # rapid to near surface - should be a hole there!
         output += "g01" + format_measure("Z",zStart) + format_feed(@speed_plung) + "\n"
      end # while places
=end      
