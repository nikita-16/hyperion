module iteration_final_mono

  use core_lib, only : idp, dp, warn, random_exp, random, error
  use type_photon, only : photon
  use sources, only : emit
  use mpi_core, only : main_process, mp_join
  use mpi_routines, only : mp_reset_first, mp_n_photons
  use peeled_images, only : make_peeled_images, peeloff_photon
  use dust_main, only : n_dust
  use grid_physics, only : energy_abs_tot, emit_from_grid, precompute_jnu_var
  use grid_propagate, only : grid_integrate_noenergy, grid_escape_tau
  use dust_interact, only : interact

  use grid_geometry, only : escaped
  use settings, only : frequencies, n_inter_max, forced_first_scattering, n_reabs_max
  use performance

  implicit none
  save

  private
  public :: do_final_mono

contains

  subroutine do_final_mono(n_photons_sources,n_photons_thermal,n_photons_chunk, peeloff_scattering_only)

    implicit none

    ! Number of photons to run, and size of chunk to use
    integer(idp),intent(in) :: n_photons_sources, n_photons_thermal, n_photons_chunk

    ! Whether to only peeloff scattered photons
    logical,intent(in) :: peeloff_scattering_only

    ! Number of photons to run in chunk, and number of photons emitted so far
    integer(idp) :: n_photons, n_photons_curr

    ! Photon object and variable to loop over photons
    integer :: ip
    type(photon) :: p

    integer :: inu

    ! Tell multi-process routines that this is the start of an iteration
    call mp_reset_first()

    ! Precompute emissivity variable locator for each cell
    call precompute_jnu_var()

    call mp_join()

    if(n_photons_sources > 0) then

       if(main_process()) call perf_header()

       call mp_join()

       ! Initialize the number of completed photons
       n_photons_curr = 0

       ! Start loop over chunks of photons
       do

          ! Find out how many photons to run
          call mp_n_photons(n_photons_sources, n_photons_curr, n_photons_chunk, n_photons)

          if(n_photons==0) exit

          ! Compute all photons in chunk
          do ip=1,n_photons

             ! Loop over monochromatic frequencies
             do inu=1,size(frequencies)

                ! Emit photon from a source
                call emit(p,inu=inu)

                ! Scale the energy by the number of photons
                p%energy = p%energy / dble(n_photons_sources)

                ! Peeloff the photons from the star
                if(make_peeled_images) then
                   if(.not.peeloff_scattering_only) call peeloff_photon(p, polychromatic=.false.)
                end if

                ! Propagate until photon is absorbed again
                call propagate(p, peeloff_scattering_only)

             end do

          end do

       end do

       ! Wait for all processes
       call mp_join()

       if(main_process()) call perf_footer()

    else
       if(main_process()) then
          write(*,*)
          write(*,'("      ---------- Skipping source emission ----------")')
          write(*,*)
       end if
    end if

    ! Tell multi-process routines that this is the start of an iteration
    call mp_reset_first()    

    call mp_join()

    if(n_photons_thermal > 0) then

       if(main_process()) call perf_header()

       call mp_join()

       n_photons_curr = 0

       ! Start loop over chunks of photons
       do

          ! Find out how many photons to run
          call mp_n_photons(n_photons_thermal, n_photons_curr, n_photons_chunk, n_photons)

          if(n_photons==0) exit

          ! Compute all photons in chunk
          do ip=1,n_photons

             ! Loop over monochromatic frequencies
             do inu=1,size(frequencies)

                p = emit_from_grid(inu=inu)

                if(p%energy > 0._dp) then

                   ! Scale energy - CHECK THIS
                   p%energy = p%energy * energy_abs_tot(p%dust_id) / dble(n_photons_thermal) * dble(n_dust)

                   ! Peeloff the photons from the dust
                   if(make_peeled_images) then
                      if(.not.peeloff_scattering_only) call peeloff_photon(p, polychromatic=.false.)
                   end if

                   ! Propagate until photon is absorbed again
                   call propagate(p, peeloff_scattering_only)

                end if

             end do

          end do

       end do

       call mp_join()

       if(main_process()) call perf_footer()

    else
       if(main_process()) then
          write(*,*)
          write(*,'("      ----------- Skipping dust emission -----------")')
          write(*,*)
       end if
    end if

  end subroutine do_final_mono

  subroutine propagate(p, peeloff_scattering_only)

    implicit none

    type(photon), intent(inout) :: p
    logical,intent(in) :: peeloff_scattering_only
    integer(idp) :: interactions
    real(dp) :: tau_achieved, tau, tau_escape
    type(photon) :: p_tmp
    real(dp) :: xi
    logical :: killed
    integer :: ia

    ! Propagate photon
    do interactions=1, n_inter_max

       ! Sample a random optical depth and propagate that optical depth
       call random_exp(tau)

       if(interactions==1) then
          if(forced_first_scattering) then
             p_tmp = p
             call grid_escape_tau(p_tmp, huge(1._dp), tau_escape, killed)
             if(tau_escape > 1.e-10_dp) then
                call random(xi)
                tau = -log(1._dp-xi*(1._dp - exp(-tau_escape)))
                p%energy = p%energy * (1._dp - exp(-tau_escape))
             end if
          end if
       end if

       call grid_integrate_noenergy(p,tau,tau_achieved)

       if(p%reabsorbed) then

          ! Loop until the photon finally escapes interacting with sources
          do ia=1,n_reabs_max

             ! The parentheses are required in the following expression to
             ! force the evaluation of the option (otherwise it gets reset
             ! because p has intent(out) from emit)
             call emit(p, reemit=.true., reemit_id=(p%reabsorbed_id), inu=(p%inu))

             ! We now peeloff the photon even if only scattered photons are
             ! wanted because this is a kind of scattering, and will not be
             ! taken into account in the raytracing.
             if(make_peeled_images) call peeloff_photon(p, polychromatic=.false.)

             ! Sample optical depth and travel
             call random_exp(tau)
             call grid_integrate_noenergy(p,tau,tau_achieved) 

             ! If we haven't intersected another source, we can proceed
             if(.not.p%reabsorbed) exit

          end do

          ! Check that we haven't reached the maximum number of successive reabsorptions
          if(ia == n_reabs_max + 1) call error('do_lucy', 'maximum number of successive re-absorptions exceeded')

       end if

       ! Check whether the photon has escaped the grid or was killed
       if(p%killed.or.escaped(p)) exit

       ! Absorb & re-emit, or scatter
       call interact(p)
       if(peeloff_scattering_only) then
          p%killed = .not.p%scattered
          if(p%killed) exit
       end if
       if(make_peeled_images) call peeloff_photon(p, polychromatic=.false.)

    end do

    if(interactions==n_inter_max+1) then
       call warn("main","photon exceeded maximum number of interactions - killing")
       p%killed = .true.
    end if

  end subroutine propagate

end module iteration_final_mono
