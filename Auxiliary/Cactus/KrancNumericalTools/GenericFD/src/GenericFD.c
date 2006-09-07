/*@@                                         
   @file      GenericFD/src/GenericFD.c
   @date      June 16 2002
   @author    S. Husa                           
   @desc

   $Id$                                  
   
   @enddesc                                     
 @@*/                                           

/*  Copyright 2004 Sascha Husa, Ian Hinder, Christiane Lechner

    This file is part of Kranc.

    Kranc is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    Kranc is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Foobar; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*/
                                              
#include "cctk.h"                             
#include "cctk_Arguments.h"                   
#include "cctk_Parameters.h"                  
#include "util_Table.h"
#include <assert.h>
            
#include "Symmetry.h"                         


#define KRANC_C
                                                
#include "GenericFD.h"


/* TODO: provide functions for differencing, use FD macros to
   evaluate == use macros to evaluate corresponding functions */

CCTK_INT sgn(CCTK_REAL x)
{
  if (x < 0)
    return -1;
  else if (x > 0)
    return 1;
  else 
    return 0;
}

/* Return the array indices in imin and imax for looping over the
   interior of the grid. imin is the index of the first grid point.
   imax is the index of the last grid point plus 1.  So a loop over
   the interior of the grid would be 

   for (i = imin; i < imax; i++)

   The indexing is C-style. Also return whether the boundary is a
   symmetry, physical or interprocessor boundary.  Carpet refinement
   boundaries are treated as interprocessor boundaries.
*/
void GenericFD_GetBoundaryInfo(cGH *cctkGH, CCTK_INT *cctk_lsh, CCTK_INT *cctk_bbox,
			       CCTK_INT *cctk_nghostzones, CCTK_INT *imin, 
			       CCTK_INT *imax, CCTK_INT *is_symbnd, 
			       CCTK_INT *is_physbnd, CCTK_INT *is_ipbnd)
{
  CCTK_INT nboundaryzones[6];
  CCTK_INT is_internal[6];
  CCTK_INT is_staggered[6];
  CCTK_INT shiftout[6];
  CCTK_INT symbnd[6];

  CCTK_INT symtable = 0;
  CCTK_INT dir = 0;
  CCTK_INT face = 0;
  CCTK_INT npoints = 0;
  CCTK_INT iret = 0;
  CCTK_INT ierr = 0;

  ierr = GetBoundarySpecification(6, nboundaryzones, is_internal, is_staggered, 
				  shiftout);
  if (ierr != 0)
    CCTK_WARN(0, "Could not obtain boundary specification");

  symtable = SymmetryTableHandleForGrid(cctkGH);
  if (symtable < 0) 
  {
    CCTK_WARN(0, "Could not obtain symmetry table");
  }  
  
  iret = Util_TableGetIntArray(symtable, 6, symbnd, "symmetry_handle");
  if (iret != 6) CCTK_WARN (0, "Could not obtain symmetry information");

  for (dir = 0; dir < 6; dir++)
  {
    is_symbnd[dir] = (symbnd[dir] >= 0);
    is_ipbnd[dir] = (cctk_bbox[dir] == 0);
    is_physbnd[dir] = (!is_ipbnd[dir] && !is_symbnd[dir]);
  }

  for (dir = 0; dir < 3; dir++)
  {
    for (face = 0; face < 2; face++)
    {
      CCTK_INT index = dir*2 + face;
      if (is_ipbnd[index])
      {
	/* Inter-processor boundary */
	npoints = cctk_nghostzones[dir];
      }
      else
      {
	/* Symmetry or physical boundary */
	npoints = nboundaryzones[index];
             
	if (is_symbnd[index])
	{
	  /* Ensure that the number of symmetry zones is the same
	     as the number of ghost zones */
	  if (npoints != cctk_nghostzones[dir])
	  {
	    CCTK_WARN (1, "The number of symmetry points is different from the number of ghost points; this is probably an error");
	  }
	}
      }

      switch(face)
      {
      case 0: /* Lower boundary */
	imin[dir] = npoints;
	break;
      case 1: /* Upper boundary */
	imax[dir] = cctk_lsh[dir] - npoints;
	break;
      default:
	CCTK_WARN(0, "internal error");
      }
    }
  }
}


void GenericFD_LoopOverEverything(cGH *cctkGH, Kranc_Calculation calc)
{
  DECLARE_CCTK_ARGUMENTS

  CCTK_INT   dir = 0;
  CCTK_INT   face = 0;
  CCTK_REAL  normal[] = {0,0,0};
  CCTK_REAL  tangent1[] = {0,0,0};
  CCTK_REAL  tangent2[] = {0,0,0};
  CCTK_INT   bmin[] = {0,0,0};
  CCTK_INT   bmax[] = {cctk_lsh[0], cctk_lsh[1], cctk_lsh[2]};

  calc(cctkGH, dir, face, normal, tangent1, tangent2, bmin, bmax, 0, NULL);
  return;
}

static void basis_on_boundary(int dir, int face, CCTK_REAL normal[3], CCTK_REAL tangent1[3], 
                              CCTK_REAL tangent2[3])
{
  for (int i = 0; i < 3; i++)
  {
    normal[i] = 0.0;
    tangent1[i] = 0.0;
    tangent2[i] = 0.0;
  }

  // Do we need these to be chosen in a more intelligent way?  For
  // example, do they need to form a right handed set, or a set of
  // constant handedness?
  normal[dir] = (face == 0) ? -1 : 1;
  tangent1[(dir + 1) % 3] = 1;
  tangent2[(dir + 2) % 3] = 1;
}


void GenericFD_LoopOverBoundary(cGH *cctkGH, Kranc_Calculation calc)
{
  DECLARE_CCTK_ARGUMENTS

  CCTK_INT   dir = 0;
  CCTK_INT   face = 0;
  CCTK_REAL  normal[] = {0,0,0};
  CCTK_REAL  tangent1[] = {0,0,0};
  CCTK_REAL  tangent2[] = {0,0,0};
  CCTK_INT   bmin[] = {0,0,0};
  CCTK_INT   bmax[] = {cctk_lsh[0], cctk_lsh[1], cctk_lsh[2]};

  CCTK_INT   is_symbnd[6], is_physbnd[6], is_ipbnd[6];
  CCTK_INT   imin[3], imax[3];

  GenericFD_GetBoundaryInfo(cctkGH, cctk_lsh, cctk_bbox, cctk_nghostzones, 
                            imin, imax, is_symbnd, is_physbnd, is_ipbnd);

 /* Loop over all faces */
  for (dir = 0; dir < 3; dir++)
  {
    for (face = 0; face < 2; face++)
    {
      /* Start by looping over the whole grid, minus the NON-PHYSICAL
         boundary points, which are set by synchronization.  */
      bmin[0] = is_physbnd[0*2+0] ? 0 : imin[0];
      bmin[1] = is_physbnd[1*2+0] ? 0 : imin[1];
      bmin[2] = is_physbnd[2*2+0] ? 0 : imin[2];
      bmax[0] = is_physbnd[0*2+1] ? cctk_lsh[0] : imax[0];
      bmax[1] = is_physbnd[1*2+1] ? cctk_lsh[1] : imax[1];
      bmax[2] = is_physbnd[2*2+1] ? cctk_lsh[2] : imax[2];

      /* Now restrict to only the boundary points on the current face */
      switch(face)
      {
      case 0:
        bmax[dir] = imin[dir];
        bmin[dir] = 0;
        break;
      case 1:
        bmin[dir] = imax[dir];
        bmax[dir] = cctk_lsh[dir];
        break;
      }

      basis_on_boundary(dir, face, normal, tangent1, tangent2);

      if (is_physbnd[dir * 2 + face])
      {
        calc(cctkGH, dir, face, normal, tangent1, tangent2, bmin, bmax, 0, NULL);
      }
    }
  }
  
  return;
}

void GenericFD_LoopOverInterior(cGH *cctkGH, Kranc_Calculation calc)
{
  DECLARE_CCTK_ARGUMENTS

  CCTK_INT   dir = 0;
  CCTK_INT   face = 0;
  CCTK_REAL  normal[] = {0,0,0};
  CCTK_REAL  tangent1[] = {0,0,0};
  CCTK_REAL  tangent2[] = {0,0,0};

  CCTK_INT   is_symbnd[6], is_physbnd[6], is_ipbnd[6];
  CCTK_INT   imin[3], imax[3];

  GenericFD_GetBoundaryInfo(cctkGH, cctk_lsh, cctk_bbox, cctk_nghostzones, 
                            imin, imax, is_symbnd, is_physbnd, is_ipbnd);

  calc(cctkGH, dir, face, normal, tangent1, tangent2, imin, imax, 0, NULL);
  
  return;
}

void GenericFD_PenaltyPrim2Char(cGH *cctkGH, CCTK_INT const dir,
                                CCTK_INT const face,
                                CCTK_REAL const * restrict const base,
                                CCTK_INT const * restrict const lbnd,
                                CCTK_INT const * restrict const lsh,
                                CCTK_INT const rhs_flag,
                                CCTK_INT const num_modes,
                                CCTK_POINTER const * restrict const modes,
                                CCTK_POINTER const * restrict const speeds,
                                Kranc_Calculation calc)
{
  DECLARE_CCTK_ARGUMENTS

  CCTK_REAL  normal[] = {0,0,0};
  CCTK_REAL  tangent1[] = {0,0,0};
  CCTK_REAL  tangent2[] = {0,0,0};
  CCTK_INT   bmin[] = {0,0,0};
  CCTK_INT   bmax[] = {cctk_lsh[0], cctk_lsh[1], cctk_lsh[2]};
  CCTK_REAL  **all_vars;
  int        i = 0;

  all_vars = malloc(num_modes*2*sizeof(CCTK_REAL *));
  assert(all_vars != NULL);

  for (i = 0; i < num_modes; i++)
  {
    all_vars[i] = (CCTK_REAL *) modes[i];
    all_vars[num_modes + i] = (CCTK_REAL *) speeds[i];
  }

  for (int d=0; d<3; ++d) {
    normal[d] = base[d];        /* A covector, index down */
    tangent1[d] = base[d+3];    /* A vector, index up */
    tangent2[d] = base[d+6];    /* A vector, index up */
  }

  calc(cctkGH, dir, face, normal, tangent1, tangent2, bmin, bmax, num_modes * 2, all_vars);

  free(all_vars);
  
  return;
}
